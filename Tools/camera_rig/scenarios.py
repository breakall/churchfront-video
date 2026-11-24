"""Black-box transport checks reusable against a separately running bridge."""

from datetime import datetime, timezone
import time

from .controller import Controller, loopback_url


def equal(actual, expected, label):
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, received {actual!r}")


def movement(controller, admin):
    controller.move("right", "up", 100).require_ok()
    admin.admin("advance", {"seconds": 2})
    fields = controller.info().require_ok().fields
    equal(fields["c.1.pan"], "200", "pan with held joystick")
    equal(fields["c.1.tilt"], "200", "tilt with held joystick")
    controller.move("stop", "up", 100).require_ok()
    admin.admin("advance", {"seconds": 1})
    fields = controller.info().require_ok().fields
    equal(fields["c.1.pan"], "200", "independent pan release")
    equal(fields["c.1.tilt"], "300", "tilt remains held")
    controller.move().require_ok()
    admin.admin("advance", {"seconds": 2})
    equal(controller.info().require_ok().fields["c.1.tilt"], "300", "explicit tilt stop")


def focus_zoom(controller, admin):
    controller.zoom("tele", 10).require_ok()
    admin.admin("advance", {"seconds": 1})
    controller.zoom("stop").require_ok()
    controller.command("control.cgi", {"focus": "manual"}).require_ok()
    controller.focus("far").require_ok()
    controller.focus("stop").require_ok()
    fields = controller.info().require_ok().fields
    equal(fields["c.1.zoom"], "3900", "zoom request")
    equal(fields["c.1.focus"], "manual", "focus mode")
    equal(fields["c.1.focus.action"], "stop", "focus release")


def preset(controller, admin):
    controller.command("control.cgi", {"pan": "900", "tilt": "-200", "zoom": "4000"}).require_ok()
    controller.preset_store(7, "Lectern α").require_ok()
    controller.command("control.cgi", {"pan": "-500", "tilt": "100"}).require_ok()
    controller.preset_recall(7).require_ok()
    fields = controller.info().require_ok().fields
    equal(fields["c.1.pan"], "900", "preset recall pan")
    equal(fields["c.1.tilt"], "-200", "preset recall tilt")
    equal(fields["p.7.name.utf8"], "Lectern α", "UTF-8 preset name")


def trace(controller, admin):
    controller.trace_record("start", 2, "Walk").require_ok()
    controller.move("right", "stop", 100).require_ok()
    admin.admin("advance", {"seconds": 2})
    controller.focus("one_shot").require_ok()
    controller.move().require_ok()
    controller.trace_record("stop").require_ok()
    controller.command("control.cgi", {"pan": "-900"}).require_ok()
    controller.trace_play("prepare", 2).require_ok()
    equal(controller.info().require_ok().fields["c.1.pan"], "0", "trace prepare")
    controller.trace_play("start", 2).require_ok()
    admin.admin("advance", {"seconds": 2})
    fields = controller.info().require_ok().fields
    equal(fields["c.1.pan"], "200", "trace recorded trajectory")
    equal(fields["t.status"], "idle", "trace completion")
    controller.trace_play("stop").require_ok()


def trace_cancel(controller, admin):
    controller.trace_record("start", 3, "Cancelled").require_ok()
    controller.move("left").require_ok()
    admin.admin("advance", {"seconds": 1})
    controller.move().require_ok()
    controller.trace_record("cancel").require_ok()
    equal(controller.trace_play("prepare", 3).livescope, "403", "cancel does not save trace")


def camera_error(controller, admin):
    admin.admin("fault", {"mode": "livescope", "code": 408, "endpoint": "control.cgi"})
    equal(controller.move("right").livescope, "408", "camera error propagation")
    admin.admin("advance", {"seconds": 1})
    equal(controller.info().require_ok().fields["c.1.pan"], "0", "rejected movement")
    controller.move("right").require_ok()
    controller.move().require_ok()


SCENARIOS = (("continuous_and_per_axis_stop", movement), ("zoom_and_focus", focus_zoom),
             ("preset_store_recall_post_utf8", preset), ("trace_record_prepare_play_stop", trace),
             ("trace_record_cancel", trace_cancel), ("camera_error_forwarding", camera_error))


def verify(target, camera_url, *, timeout=2):
    loopback_url(target)
    loopback_url(camera_url)
    started = time.monotonic()
    checks = []
    with Controller(camera_url, timeout=timeout) as admin:
        meta = admin.admin("meta")
        if meta.get("kind") != "canon-camera-test-rig" or meta.get("version") != 1:
            raise ValueError("camera inspection endpoint is not this test rig")
        if meta["clock"] != "manual":
            raise ValueError("automated scenarios require --clock manual")
        for name, scenario in SCENARIOS:
            at = time.monotonic()
            try:
                admin.admin("reset", {"keep_sessions": True})
                with Controller(target, timeout=timeout) as controller:
                    try:
                        controller.connect().require_ok()
                        scenario(controller, admin)
                    finally:
                        if controller.session:
                            controller.release().require_ok()
                checks.append({"name": name, "passed": True,
                               "duration_ms": round((time.monotonic() - at) * 1000, 3),
                               "camera_events": admin.admin("events")["events"]})
            except Exception as error:
                checks.append({"name": name, "passed": False,
                               "error": f"{type(error).__name__}: {error}",
                               "duration_ms": round((time.monotonic() - at) * 1000, 3),
                               "camera_events": admin.admin("events")["events"]})
    return {"schema_version": 1, "generated_at": datetime.now(timezone.utc).isoformat(),
            "mode": "direct_simulator_baseline" if loopback_url(target) == loopback_url(camera_url)
                    else "external_target_transport",
            "camera_run_id": meta["run_id"], "target": target, "camera": camera_url,
            "ownership_profile": meta["ownership"], "passed": all(check["passed"] for check in checks),
            "duration_ms": round((time.monotonic() - started) * 1000, 3), "checks": checks,
            "tracking_handoff_verified": False,
            "not_covered": ["Churchfront tracking authorization and helper IPC/lifecycle",
                            "actual RC-IP100 firmware request fidelity and native tracking controls",
                            "camera image processing, lens and mechanical behavior"]}
