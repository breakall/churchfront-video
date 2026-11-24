"""Checks for an already registered, isolated macOS bridge service.

The caller owns registration, its registrar fixture, process termination and
cleanup. This module operates only the loopback interfaces and records evidence.
"""

from datetime import datetime, timezone
from pathlib import Path
import time
import traceback

from .bridge_scenarios import AppClient, assert_revoked, command_ok, rejection
from .controller import Controller, loopback_url
from .scenarios import equal, verify


def _service_snapshot(snapshot_service):
    value = snapshot_service()
    safe = {key: value[key] for key in ("pid", "state", "registered", "label", "last_exit_code", "runs")
            if key in value}
    if not isinstance(safe.get("pid"), int) or safe["pid"] <= 0:
        raise AssertionError("the managed helper does not have a live service PID")
    equal(safe.get("registered"), True, "isolated service is registered")
    return safe


def _lifecycle_evidence(value):
    value = value or {}
    return {key: value[key] for key in ("registrar_pid", "exit_code", "event", "helper_pid", "state")
            if key in value}


def _forwarding(hardware, admin):
    """Known one-second motion, even when the previous test reached a limit."""
    # Lifecycle waits can exceed the simulator's idle HTTP timeout. Only the
    # observation socket is reopened; movement commands are never replayed.
    admin.connection.close()
    before = int(admin.admin("state")["info"]["c.1.pan"])
    direction, delta = ("left", -100) if before > 16000 else ("right", 100)
    hardware.move(direction, speed=100).require_ok()
    admin.admin("advance", {"seconds": 1})
    equal(int(admin.admin("state")["info"]["c.1.pan"]), before + delta,
          "controller movement traverses the managed service")
    hardware.move().require_ok()
    admin.admin("advance", {"seconds": 1})
    equal(int(admin.admin("state")["info"]["c.1.pan"]), before + delta,
          "controller release traverses the managed service")


def verify_service_transport(controller_url, camera_url):
    """Run the existing six transport scenarios through the managed listener."""
    return verify(controller_url, camera_url)


def verify_service(controller_url, app_url, camera_url, token, *, label,
                   snapshot_service, quit_registrar, crash_registrar, restart_helper,
                   registration_method="SMAppService.agent"):
    """Verify the caller's isolated service using its owned lifecycle hooks.

    ``snapshot_service()`` returns ``{pid, state, registered}`` from launchd.
    Registrar hooks return ``{registrar_pid, exit_code}``, after waiting for the
    actual owned fixture process to quit/crash. ``restart_helper()`` waits for
    launchd to replace the owned helper, then returns ``{controller_url, app_url,
    pid}`` from fresh ready metadata. No hook may terminate an unrelated process.

    The report deliberately leaves cleanup_verified false; the owner must set it
    only after unregistering this isolated service and observing its removal.
    """
    for url in (controller_url, app_url, camera_url):
        loopback_url(url)
    if registration_method not in ("SMAppService.agent", "launchctl.bootstrap", "test_fixture_only"):
        raise ValueError("record the actual service registration method")
    started = time.monotonic()
    initial = _service_snapshot(snapshot_service)
    transport = verify_service_transport(controller_url, camera_url)
    checks = [{**check, "name": "service/transport/" + check["name"]} for check in transport["checks"]]
    snapshots = [{"event": "initial", **initial}]
    registrar_events = []
    with Controller(camera_url) as admin, Controller(controller_url) as hardware:
        app = AppClient(app_url, token)

        def run(name, action):
            at = time.monotonic()
            admin.connection.close()
            sequence = admin.admin("events")["last_sequence"]
            failure_frames = []
            try:
                action()
                passed, error = True, None
            except Exception as failure:
                passed, error = False, f"{type(failure).__name__}: {failure}"
                failure_frames = [{"file": Path(frame.filename).name, "line": frame.lineno,
                                   "function": frame.name}
                                  for frame in traceback.extract_tb(failure.__traceback__)[-4:]]
            admin.connection.close()
            check = {"name": "service/" + name, "passed": passed,
                     "duration_ms": round((time.monotonic() - at) * 1000, 3),
                     "camera_events": [event for event in admin.admin("events")["events"]
                                       if event["sequence"] > sequence]}
            if error:
                check["error"] = error
                check["failure_frames"] = failure_frames
            checks.append(check)

        def takeover():
            admin.admin("reset", {"keep_sessions": True})
            hardware.connect().require_ok()
            lease = app.start(app.connect())
            command_ok(app.command(lease, {"pan": "left", "pan.speed": "100"}))
            hardware.move("right").require_ok()
            assert_revoked(app, lease, admin)
            hardware.move().require_ok()
            equal(app.status()["authorized"], False, "physical release keeps tracking off")
            app.request("disconnect", app.current(lease)).json()
            _forwarding(hardware, admin)
            current = _service_snapshot(snapshot_service)
            equal(current["pid"], initial["pid"], "app disconnect preserves the managed helper process")
            snapshots.append({"event": "app_disconnect", **current})

        run("authenticated_takeover_and_app_disconnect", takeover)

        def registrar_exit(hook, event, *, crash):
            result = _lifecycle_evidence(hook())
            if not isinstance(result.get("registrar_pid"), int) or result["registrar_pid"] <= 0:
                raise AssertionError("registrar hook did not identify its actual owned process")
            if crash:
                if not isinstance(result.get("exit_code"), int) or result["exit_code"] >= 0:
                    raise AssertionError("registrar crash was not observed as signal termination")
            else:
                equal(result.get("exit_code"), 0, "registrar fixture exits normally")
            registrar_events.append({"event": event, **result})
            # The actual fixture process owns and heartbeats a production Swift
            # client lease. A crash must expire that lease; a normal quit closes it.
            deadline = time.monotonic() + 8
            while True:
                status = app.status()
                if status.get("connection") is None:
                    break
                if time.monotonic() >= deadline:
                    raise AssertionError("terminated registrar retained an app lease")
                time.sleep(0.05)
            equal(status["authorized"], False, "terminated registrar leaves tracking disabled")
            _forwarding(hardware, admin)
            current = _service_snapshot(snapshot_service)
            equal(current["pid"], initial["pid"], "registrar termination preserves helper PID")
            snapshots.append({"event": event, **current})

        run("registrar_quit_preserves_physical_forwarding",
            lambda: registrar_exit(quit_registrar, "registrar_quit", crash=False))
        run("registrar_crash_preserves_physical_forwarding",
            lambda: registrar_exit(crash_registrar, "registrar_crash", crash=True))

        def helper_restart():
            hardware.move("right", speed=10000).require_ok()
            admin.admin("advance", {"seconds": 20})
            state = admin.admin("state")
            equal(state["info"]["c.1.pan.status"], "0", "held camera reached travel limit")
            equal(state["commanded_axes"], ["pan"], "stopped telemetry does not imply joystick release")
            ready = restart_helper()
            for key in ("controller_url", "app_url"):
                loopback_url(ready[key])
            current = _service_snapshot(snapshot_service)
            equal(current["pid"], ready["pid"], "launchd PID matches fresh helper ready metadata")
            if current["pid"] == initial["pid"]:
                raise AssertionError("launchd did not replace the terminated helper process")
            snapshots.append({"event": "helper_restarted", **current})
            recovered = AppClient(ready["app_url"], token)
            recovered.observations = app.observations
            lease = recovered.connect()
            status = recovered.status()
            equal(status["authorized"], False, "launchd restart keeps tracking unauthorized")
            equal(status["recoveryRequired"], True, "helper restart retains the conservative recovery fence")
            rejection(recovered.request("start", recovered.current(lease)))
            with Controller(ready["controller_url"]) as controller:
                controller.connect().require_ok()
                controller.move().require_ok()
                controller.zoom("stop").require_ok()
                controller.focus("stop").require_ok()
                controller.info().require_ok()
                fresh = recovered.start(recovered.current(lease))
                command_ok(recovered.command(fresh, {"pan": "left", "pan.speed": "100"}))
                recovered.request("stop", fresh).json()
                equal(recovered.status()["authorized"], False, "explicit stop releases restarted helper authorization")
                _forwarding(controller, admin)

        run("launchd_restart_requires_explicit_physical_release", helper_restart)
        app_events = list(app.observations)

    all_passed = bool(checks) and all(check["passed"] for check in checks)
    return {"schema_version": 1, "generated_at": datetime.now(timezone.utc).isoformat(),
            "mode": "macos_background_service", "service_label": label,
            "registration_method": registration_method,
            "passed": all_passed, "checks": checks,
            "duration_ms": round((time.monotonic() - started) * 1000, 3),
            "service_observations": snapshots, "registrar_observations": registrar_events,
            "app_events": app_events, "cleanup_verified": False,
            "background_service_verified": all_passed and registration_method != "test_fixture_only",
            "tracking_handoff_verified": False,
            "not_covered": ["actual Churchfront UI and tracking engine lifecycle",
                            "real RC-IP100/camera firmware and native tracking controls",
                            "background operation after reboot or user logout"]}
