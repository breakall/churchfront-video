"""Independent relays prove the runner detects forwarding regressions."""

import http.client
from contextlib import closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import unittest
from urllib.parse import parse_qs, urlsplit

from camera_rig.camera import CameraSimulator
from camera_rig.controller import Controller
from camera_rig.scenarios import verify


class ReferenceRelay:
    """Test fixture only: forward HTTP or deliberately introduce one defect."""

    def __init__(self, upstream, defect=None):
        self.upstream = urlsplit(upstream)
        self.defect = defect

    def __enter__(self):
        relay = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def forward(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                parsed = urlsplit(self.path)
                values = parse_qs(parsed.query)
                ignored = (relay.defect == "drop_stores" and parsed.path.endswith("preset/set")
                           or relay.defect == "swallow_stop" and values.get("pan") == ["stop"])
                if ignored:
                    status, payload, headers = 200, b"", [("Livescope-Status", "0")]
                else:
                    with closing(http.client.HTTPConnection(relay.upstream.hostname, relay.upstream.port, timeout=2)) as connection:
                        connection.request(self.command, self.path, body=body,
                                           headers={k: v for k, v in self.headers.items()
                                                    if k.lower() not in ("host", "connection")})
                        response = connection.getresponse()
                        status, payload, headers = response.status, response.read(), response.getheaders()
                self.send_response(status)
                for key, value in headers:
                    if key.lower() not in ("connection", "content-length", "transfer-encoding", "server", "date"):
                        self.send_header(key, value)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            do_GET = forward
            do_POST = forward

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={"poll_interval": 0.02}, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        return self

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


class ExternalTargetTests(unittest.TestCase):
    def test_camera_and_controller_launch_as_independent_programs(self):
        launcher = str(Path(__file__).resolve().parents[2] / "camera-rig.py")
        camera = subprocess.Popen([sys.executable, launcher, "camera", "--port", "0", "--clock", "manual"],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            ready = queue.Queue()
            threading.Thread(target=lambda: ready.put(camera.stdout.readline()), daemon=True).start()
            url = json.loads(ready.get(timeout=5))["url"]

            def command(*args):
                result = subprocess.run([sys.executable, launcher, *args], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                return json.loads(result.stdout)

            command("controller", "--target", url, "pan", "right")
            command("advance", "--camera", url, "2")
            info = command("controller", "--target", url, "info")
            self.assertEqual(info["fields"]["c.1.pan"], "200")
            command("controller", "--target", url, "pan", "stop")
            state = command("inspect", "--camera", url, "state")
            self.assertEqual(state["commanded_axes"], [])
            self.assertEqual(state["session_count"], 0)
        finally:
            camera.terminate()
            try:
                _, errors = camera.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                camera.kill()
                camera.communicate()
                raise
        self.assertEqual(camera.returncode, 0, errors)

    def test_runner_accepts_a_separate_working_relay_in_both_ownership_profiles(self):
        for profile in ("documented", "exclusive"):
            with self.subTest(profile=profile), CameraSimulator(clock="manual", ownership=profile) as camera:
                with ReferenceRelay(camera.url) as relay:
                    report = verify(relay.url, camera.url)
                    self.assertTrue(report["passed"], report)
                    self.assertEqual(report["mode"], "external_target_transport")

    def test_runner_rejects_a_relay_that_lies_about_storing_a_preset(self):
        with CameraSimulator(clock="manual") as camera, ReferenceRelay(camera.url, "drop_stores") as relay:
            report = verify(relay.url, camera.url)
        self.assertFalse(report["passed"])
        checks = {check["name"]: check for check in report["checks"]}
        self.assertTrue(checks["continuous_and_per_axis_stop"]["passed"])
        self.assertFalse(checks["preset_store_recall_post_utf8"]["passed"])
        self.assertTrue(checks["preset_store_recall_post_utf8"]["camera_events"])

    def test_runner_rejects_a_relay_that_swallows_joystick_release(self):
        with CameraSimulator(clock="manual") as camera, ReferenceRelay(camera.url, "swallow_stop") as relay:
            report = verify(relay.url, camera.url)
        self.assertFalse(report["passed"])
        self.assertFalse(report["checks"][0]["passed"])
        self.assertIn("independent pan release", report["checks"][0]["error"])

    def test_cli_verify_returns_failure_and_saves_evidence_for_a_broken_relay(self):
        launcher = Path(__file__).resolve().parents[2] / "camera-rig.py"
        with tempfile.TemporaryDirectory() as directory, CameraSimulator(clock="manual") as camera:
            with ReferenceRelay(camera.url, "drop_stores") as relay:
                output = Path(directory) / "negative-control.json"
                result = subprocess.run([sys.executable, str(launcher), "verify", "--camera", camera.url,
                                         "--target", relay.url, "--output", str(output)],
                                        capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
                self.assertFalse(json.loads(output.read_text())["passed"])

    def test_two_controller_clients_can_exercise_a_shared_endpoint(self):
        with CameraSimulator(clock="manual", ownership="exclusive") as camera:
            with ReferenceRelay(camera.url) as relay, Controller(relay.url, actor="software") as software:
                with Controller(relay.url) as hardware:
                    software.connect().require_ok()
                    software.move("left").require_ok()
                    hardware.connect().require_ok()
                    hardware.focus("one_shot").require_ok()
                    self.assertEqual(software.move("right").livescope, "301")
                    events = hardware.admin("events")["events"]
                    self.assertEqual({e["actor"] for e in events}, {"controller", "software"})
