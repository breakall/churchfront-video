"""Read-only evidence for actual Churchfront tracking before/after RC takeover.

The UI observer starts tracking and sends the physical command separately. This
module never changes app tracking, opens a helper lease, or moves a camera.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import json
from pathlib import Path
import time

from .bridge_scenarios import AppClient
from .cli import write_json
from .controller import Controller, loopback_url
from .scenarios import equal


def app_status(token_file):
    token = Path(token_file).read_text().strip()
    body = json.dumps({"name": "get_status", "arguments": {}}).encode()
    connection = http.client.HTTPConnection("127.0.0.1", 9911, timeout=3)
    try:
        connection.request("POST", "/call", body=body,
                           headers={"X-CueVideo-Token": token, "Content-Type": "application/json"})
        response = connection.getresponse()
        payload = response.read(2_097_153)
        if response.status != 200 or len(payload) > 2_097_152:
            raise RuntimeError(f"Actual app status failed: HTTP {response.status}")
        value = json.loads(payload)
        if not isinstance(value, dict) or "error" in value:
            raise RuntimeError("Actual app did not return a get_status result")
        return value
    finally:
        connection.close()


def camera_status(value, host):
    cameras = [camera for camera in value.get("cameras", [])
               if camera.get("protocol") == "canonXC" and camera.get("host") == host]
    equal(len(cameras), 1, "exactly one loopback Canon camera in the real app")
    return cameras[0]


def safe_camera(value):
    tracking = value.get("tracking")
    if isinstance(tracking, dict):
        tracking = {key: tracking[key] for key in ("state", "framing", "picture_is") if key in tracking}
    return {"camera_alias": "camera-1", "tracking": tracking,
            **{key: value[key] for key in ("answering", "has_control", "on_live", "on_next") if key in value}}


def safe_helper(value):
    identity = value.get("connection")
    alias = hashlib.sha256(identity.encode()).hexdigest()[:24] if isinstance(identity, str) else None
    keys = ("version", "generation", "authorized", "heldAxes", "health", "manualTakeover",
            "recoveryRequired", "configurationID", "helperBuild")
    return {**{key: value[key] for key in keys if key in value}, "app_connection_alias": alias}


def physical_event(event):
    if event.get("actor") != "controller":
        return False
    if event.get("endpoint") in ("preset/set", "trace/set", "trace/control"):
        return True
    if event.get("endpoint") != "control.cgi":
        return False
    keys = {key.removeprefix("c.1.") for key in event.get("parameters", {})}
    return bool(keys & {"pan", "tilt", "zoom", "focus", "focus.action", "p"})


def verify_snapshot(phase, camera_url, helper_ready, control_token_file, *, baseline=None):
    host, _ = loopback_url(camera_url)
    ready = json.loads(Path(helper_ready).read_text())
    equal(ready["version"], 1, "helper interface version")
    loopback_url(ready["app_url"])
    app = AppClient(ready["app_url"], Path(ready["token_file"]).read_text())
    checks = []
    result = {"schema_version": 1, "generated_at": datetime.now(timezone.utc).isoformat(),
              "mode": "actual_app_tracking_takeover_backend", "phase": phase,
              "actual_ui_verified": False, "actual_app_takeover_verified": False,
              "checks": checks, "passed": False,
              "not_covered": ["visible tracking button/badge; observed separately by the UI test",
                              "real camera/controller firmware and tracking image-processing quality"]}
    try:
        with Controller(camera_url) as admin:
            equal(admin.admin("meta")["kind"], "canon-camera-test-rig", "camera is the isolated simulator")
            deadline = time.monotonic() + (3 if phase == "after" else 0)
            while True:
                camera = camera_status(app_status(control_token_file), host)
                helper = app.status()
                if phase != "after" or (camera.get("tracking") is False and not helper["authorized"]):
                    break
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.05)
            journal = admin.admin("events")
        result.update(camera=safe_camera(camera), helper=safe_helper(helper),
                      camera_sequence=journal["last_sequence"])
        if phase == "before":
            if not isinstance(camera.get("tracking"), dict):
                raise AssertionError("The actual app must have an active tracking session before RC takeover")
            equal(helper["authorized"], True, "helper authorized the real app's tracking session")
            if helper.get("connection") is None:
                raise AssertionError("Actual app has no helper connection")
            checks.append({"name": "actual_app_tracking_active_and_helper_authorized", "passed": True})
            result["camera_events"] = journal["events"]
        else:
            if not baseline or baseline.get("phase") != "before" or not baseline.get("passed"):
                raise ValueError("after phase requires a successful before snapshot")
            equal(camera.get("tracking"), False, "actual app tracking session stopped")
            checks.append({"name": "actual_app_tracking_session_stopped", "passed": True})
            equal(helper["authorized"], False, "helper authorization revoked")
            equal(helper["manualTakeover"], True, "helper reports physical takeover")
            if helper["generation"] <= baseline["helper"]["generation"]:
                raise AssertionError("Physical takeover did not advance the helper generation")
            checks.append({"name": "physical_takeover_revoked_tracking_authorization", "passed": True})
            equal(result["helper"]["app_connection_alias"], baseline["helper"]["app_connection_alias"],
                  "actual app lease identity survives takeover")
            if result["helper"]["app_connection_alias"] is None:
                raise AssertionError("The actual app connection ended during takeover")
            checks.append({"name": "same_real_app_connection_remains_attached", "passed": True})
            events = [event for event in journal["events"] if event["sequence"] > baseline["camera_sequence"]]
            if not any(physical_event(event) for event in events):
                raise AssertionError("No new simulated physical-control request reached the camera")
            result["camera_events"] = events
            checks.append({"name": "physical_command_reached_camera_after_baseline", "passed": True})
            result["actual_app_takeover_verified"] = True
        result["passed"] = True
    except Exception as error:
        checks.append({"name": "tracking_takeover_snapshot", "passed": False,
                       "error": f"{type(error).__name__}: {error}"})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", required=True, choices=("before", "after"))
    parser.add_argument("--camera", required=True)
    parser.add_argument("--helper-ready", required=True, type=Path)
    parser.add_argument("--control-token-file", required=True, type=Path)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    baseline = json.loads(args.baseline.read_text()) if args.baseline else None
    result = verify_snapshot(args.phase, args.camera, args.helper_ready, args.control_token_file, baseline=baseline)
    write_json(args.output, result)
    for check in result["checks"]:
        print(("PASS" if check["passed"] else "FAIL"), check["name"])
        if not check["passed"]:
            print("  " + check["error"])
    print("Report:", args.output)
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
