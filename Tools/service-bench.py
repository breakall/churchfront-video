#!/usr/bin/env python3
"""Exercise an isolated, simulator-only SMAppService owner and clean it up."""

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import signal
import subprocess
import sys
import time

from camera_rig.camera import CameraSimulator
from camera_rig.cli import write_json
from camera_rig.controller import Controller, loopback_url
from camera_rig.service_scenarios import verify_service


ROOT = Path(__file__).resolve().parent.parent


class ServiceFixture:
    def __init__(self, directory, helper, camera_url):
        self.directory = directory.resolve()
        self.directory.mkdir(parents=True, mode=0o700)
        self.label = "com.churchfront.cuevideo.camera-bridge.bench." + secrets.token_hex(6)
        self.bundle = self.directory / "Camera Bridge Service Bench.app"
        self.manager = self.bundle / "Contents/MacOS/BenchRegistrar"
        self.helper = self.bundle / "Contents/Helpers/camera-control-bridge"
        self.source_helper = helper.resolve()
        self.camera_url = camera_url
        self.ready_file = self.directory / "ready.json"
        self.token_file = self.directory / "app-token"
        self.registration_attempted = False
        self.cleanup = {}

    def registrar(self, action):
        result = subprocess.run([str(self.manager), action], capture_output=True, text=True, timeout=20)
        try:
            value = json.loads(result.stdout)
        except ValueError:
            value = {"error": "Registrar did not return JSON", "stderr": result.stderr[:2000]}
        return {**value, "exit_code": result.returncode}

    def prepare(self):
        loopback_url(self.camera_url)
        if not self.source_helper.is_file():
            raise ValueError("Build the application bundle before running service-bench")
        contents = self.bundle / "Contents"
        for name in ("MacOS", "Helpers", "Library/LaunchAgents"):
            (contents / name).mkdir(parents=True)
        shutil.copy2(self.source_helper, self.helper)
        subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5",
                        str(ROOT / "Tools/service_bench/Registrar.swift"),
                        str(ROOT / "Packages/CameraControlBridge/Sources/CameraBridgeClient/Client.swift"),
                        str(ROOT / "Packages/CameraControlBridge/Sources/CameraBridgeClient/Contract.swift"),
                        "-o", str(self.manager)], check=True, capture_output=True, text=True, timeout=120)
        plist_name = self.label + ".plist"
        info = {"CFBundleIdentifier": self.label + ".owner", "CFBundleExecutable": "BenchRegistrar",
                "CFBundleName": "Camera Bridge Service Bench", "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", "LSUIElement": True,
                "CameraBridgeBenchAgentPlist": plist_name}
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        config_file = self.directory / "helper.json"
        write_json(config_file, {"cameraURL": self.camera_url, "listenHost": "127.0.0.1",
                               "controllerAddress": "127.0.0.1", "controllerPort": 0, "appPort": 0,
                               "tokenFile": str(self.token_file), "readyFile": str(self.ready_file),
                               "diagnosticsFile": str(self.directory / "diagnostics.jsonl"),
                               "diagnosticsEnabled": True, "requestTimeout": 2, "leaseTimeout": 3})
        config_file.chmod(0o600)
        template = plistlib.loads((ROOT / "Resources/LaunchAgents/com.churchfront.cuevideo.camera-bridge.plist").read_bytes())
        template.update({"Label": self.label,
                         "ProgramArguments": ["camera-control-bridge", "--config", str(config_file)],
                         "StandardOutPath": str(self.directory / "helper.stdout"),
                         "StandardErrorPath": str(self.directory / "helper.stderr")})
        (contents / "Library/LaunchAgents" / plist_name).write_bytes(plistlib.dumps(template))
        for path in (self.helper, self.manager, self.bundle):
            subprocess.run(["codesign", "--force", "--sign", "-", str(path)],
                           check=True, capture_output=True, text=True, timeout=20)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(self.bundle)],
                       check=True, capture_output=True, text=True, timeout=20)

    def launchctl(self):
        return subprocess.run(["launchctl", "print", f"gui/{os.getuid()}/{self.label}"],
                              capture_output=True, text=True, timeout=10)

    def ready(self, *, previous_pid=None, timeout=35):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.ready_file.exists():
                value = json.loads(self.ready_file.read_text())
                if value.get("pid") != previous_pid and self.owns_pid(value.get("pid")):
                    loopback_url(value["controller_url"])
                    loopback_url(value["app_url"])
                    expected = "protocol1:" + hashlib.sha256(self.helper.read_bytes()).hexdigest()[:24]
                    if value.get("helper_build") != expected:
                        raise AssertionError("The managed helper's executable identity does not match its signed image")
                    return value
            time.sleep(0.1)
        raise TimeoutError("launchd did not publish a live helper within the bounded wait")

    def owns_pid(self, pid):
        if not isinstance(pid, int) or pid <= 0:
            return False
        library = ctypes.CDLL("/usr/lib/libproc.dylib")
        function = library.proc_pidpath
        function.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        function.restype = ctypes.c_int
        path = ctypes.create_string_buffer(4096)
        size = function(pid, path, len(path))
        return size > 0 and Path(os.fsdecode(path.value)).resolve() == self.helper.resolve()

    def snapshot(self):
        ready = self.ready(timeout=2)
        diagnostic = self.launchctl()
        return {"pid": ready["pid"], "state": "running" if diagnostic.returncode == 0 else "not_loaded",
                "registered": self.registrar("status").get("status") == "enabled", "label": self.label}

    def terminate_holder(self, crash):
        holder_ready = self.directory / ("crash-app-ready.json" if crash else "quit-app-ready.json")
        with (self.directory / "registrar.stdout").open("a") as output:
            process = subprocess.Popen([str(self.manager), "hold-app", str(self.ready_file), str(holder_ready)],
                                       stdout=output, stderr=output)
            try:
                deadline = time.monotonic() + 10
                while not holder_ready.exists():
                    if process.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError("Registrar fixture did not open its authenticated helper lease")
                    time.sleep(0.05)
                process.kill() if crash else process.terminate()
                code = process.wait(timeout=8)
                return {"registrar_pid": process.pid, "exit_code": code}
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)

    def restart_helper(self):
        before = self.ready(timeout=2)
        if not self.owns_pid(before["pid"]):
            raise RuntimeError("Refusing to terminate a process not owned by this fixture")
        os.kill(before["pid"], signal.SIGKILL)
        return self.ready(previous_pid=before["pid"], timeout=35)

    def remove(self):
        if not self.registration_attempted:
            self.cleanup = {"attempted": False, "verified": True}
            return
        try:
            removal = self.registrar("unregister")
        except Exception as error:
            removal = {"error": f"{type(error).__name__}: {error}", "exit_code": -1}
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if self.launchctl().returncode != 0:
                break
            time.sleep(0.1)
        try:
            state = self.registrar("status")
        except Exception as error:
            state = {"error": f"{type(error).__name__}: {error}"}
        loaded = self.launchctl().returncode == 0
        ready = json.loads(self.ready_file.read_text()) if self.ready_file.exists() else {}
        alive = self.owns_pid(ready.get("pid"))
        self.cleanup = {"attempted": True, "unregister": removal, "status": state.get("status"),
                        "job_absent": not loaded, "helper_absent": not alive,
                        "verified": state.get("status") == "notRegistered" and not loaded and not alive}
        if not self.cleanup["verified"]:
            # Emergency cleanup targets only the unique label this harness created.
            subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{self.label}"], capture_output=True, timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, default=ROOT / "Churchfront Video.app/Contents/Helpers/camera-control-bridge")
    parser.add_argument("--output", type=Path, default=ROOT / ".camera-rig/background-service-verification.json")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("This test requires macOS SMAppService and launchd")
    def interrupted(*_):
        raise KeyboardInterrupt("Service bench interrupted; unregistering its owned test service")
    signal.signal(signal.SIGTERM, interrupted)
    # A service has independent TCC permissions; runtime test data must not live
    # in protected Documents. Production uses Application Support instead.
    run = Path("/private/tmp") / ("camera-control-service-bench-" + secrets.token_hex(6))
    fixture = None
    report = {"mode": "macos_background_service", "passed": False, "registration_method": "SMAppService.agent"}
    try:
        with CameraSimulator(clock="manual") as camera:
            fixture = ServiceFixture(run, args.helper, camera.url)
            try:
                fixture.prepare()
                fixture.registration_attempted = True
                result = fixture.registrar("register")
                report.update(service_label=fixture.label, registration=result)
                if result.get("exit_code") != 0 or result.get("status") != "enabled":
                    report["blocked"] = "macOS did not enable the isolated service"
                else:
                    ready = fixture.ready()
                    report = {**report, **verify_service(ready["controller_url"], ready["app_url"], camera.url,
                        fixture.token_file.read_text(), label=fixture.label,
                        snapshot_service=fixture.snapshot,
                        quit_registrar=lambda: fixture.terminate_holder(False),
                        crash_registrar=lambda: fixture.terminate_holder(True),
                        restart_helper=fixture.restart_helper)}
            finally:
                fixture.remove()
                report["cleanup"] = fixture.cleanup
                report["cleanup_verified"] = fixture.cleanup.get("verified", False)
                report["passed"] = report.get("passed", False) and report["cleanup_verified"]
    except (Exception, KeyboardInterrupt) as error:
        report["passed"] = False
        report["error"] = f"{type(error).__name__}: {error}"
    write_json(args.output, report)
    for check in report.get("checks", []):
        print(("PASS" if check["passed"] else "FAIL"), check["name"])
        if not check["passed"]:
            print("  " + check["error"])
    print(json.dumps({key: report.get(key) for key in ("passed", "registration", "blocked", "error", "cleanup_verified")}, indent=2))
    print("Report:", args.output)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
