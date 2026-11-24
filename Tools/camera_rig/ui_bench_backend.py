"""Camera-side evidence for the real application's UI recovery rehearsal.

The UI observer owns screen interaction, app configuration and service lifetime.
This module never opens an app lease or changes application/service settings.
"""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import time

from .bridge_scenarios import AppClient
from .cli import write_json
from .controller import Controller, loopback_url
from .scenarios import equal


def safe_status(value):
    fields = ("version", "generation", "authorized", "heldAxes", "health", "manualTakeover",
              "recoveryRequired", "configurationID", "helperBuild")
    return {**{name: value[name] for name in fields if name in value},
            "app_attached": value.get("connection") is not None}


def verify_recovered_route(camera_url, helper_ready, *, timeout=5):
    loopback_url(camera_url)
    ready = json.loads(Path(helper_ready).read_text())
    equal(ready["version"], 1, "helper ready interface version")
    controller_url, app_url = ready["controller_url"], ready["app_url"]
    loopback_url(controller_url)
    loopback_url(app_url)
    token = Path(ready["token_file"]).read_text()
    app = AppClient(app_url, token)
    began = time.monotonic()
    checks, events = [], []
    before_status, after_status = {}, {}
    try:
        # Poll only status. connect() here would replace the real UI app's lease.
        deadline = time.monotonic() + timeout
        while True:
            before_status = app.status()
            if before_status.get("connection") is not None:
                break
            if time.monotonic() >= deadline:
                raise AssertionError("Churchfront has not attached an app lease to the recovered helper")
            time.sleep(0.05)
        equal(before_status["health"], "ready", "recovered camera route is ready")
        equal(before_status["authorized"], False, "service recovery does not authorize tracking")
        checks.append({"name": "app_lease_attached_with_tracking_off", "passed": True})

        with Controller(camera_url) as admin, Controller(controller_url) as hardware:
            meta = admin.admin("meta")
            equal(meta["kind"], "canon-camera-test-rig", "camera is the isolated test rig")
            equal(meta["clock"], "manual", "camera clock is deterministic")
            sequence = admin.admin("events")["last_sequence"]
            before = int(admin.admin("state")["info"]["c.1.pan"])
            direction, delta = ("left", -100) if before > 16000 else ("right", 100)
            try:
                hardware.connect().require_ok()
                hardware.move(direction, speed=100).require_ok()
                admin.admin("advance", {"seconds": 1})
                moved = int(admin.admin("state")["info"]["c.1.pan"])
                equal(moved, before + delta, "physical command traverses the restarted UI-managed helper")
                checks.append({"name": "restarted_helper_forwards_physical_movement", "passed": True,
                               "pan_before": before, "pan_after": moved})
            finally:
                # The release is explicit and is never automatically retried.
                hardware.move().require_ok()
                hardware.zoom("stop").require_ok()
                hardware.focus("stop").require_ok()
            admin.admin("advance", {"seconds": 1})
            equal(int(admin.admin("state")["info"]["c.1.pan"]), before + delta,
                  "physical release stops the simulated camera")
            hardware.info().require_ok()
            checks.append({"name": "physical_release_stops_camera", "passed": True})
            events = [event for event in admin.admin("events")["events"] if event["sequence"] > sequence]
        after_status = app.status()
        equal(after_status["authorized"], False, "physical control does not re-enable tracking")
        equal(after_status.get("connection"), before_status["connection"],
              "real app connection survives physical verification")
        checks.append({"name": "app_lease_stays_connected_and_tracking_off", "passed": True})
    except Exception as error:
        checks.append({"name": "recovered_route_verification", "passed": False,
                       "error": f"{type(error).__name__}: {error}"})
    return {"schema_version": 1, "generated_at": datetime.now(timezone.utc).isoformat(),
            "mode": "actual_ui_recovery_backend", "passed": bool(checks) and all(c["passed"] for c in checks),
            "helper_pid": ready.get("pid"), "helper_build": ready.get("helper_build"),
            "camera": camera_url, "checks": checks, "camera_events": events,
            "before_status": safe_status(before_status), "after_status": safe_status(after_status),
            "duration_ms": round((time.monotonic() - began) * 1000, 3),
            "actual_ui_verified": False,
            "not_covered": ["visible unavailable message and button activation; observed separately by the UI test",
                            "service registration and cleanup; owned by the UI test harness",
                            "real camera/controller firmware and tracking image processing"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--camera", required=True)
    parser.add_argument("--helper-ready", required=True, type=Path)
    parser.add_argument("--output", default=".camera-rig/ui-recovery-backend.json", type=Path)
    args = parser.parse_args()
    report = verify_recovered_route(args.camera, args.helper_ready)
    write_json(args.output, report)
    for check in report["checks"]:
        print(("PASS" if check["passed"] else "FAIL"), check["name"])
        if not check["passed"]:
            print("  " + check["error"])
    print("Report:", args.output)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
