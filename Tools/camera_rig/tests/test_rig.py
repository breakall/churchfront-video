import unittest
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.request import Request, urlopen

from camera_rig.camera import CameraSimulator


class CameraWireTests(unittest.TestCase):
    def test_camera_identifies_itself_over_canon_http(self):
        with CameraSimulator(clock="manual") as camera:
            with urlopen(camera.url + "/-wvhttp-01-/info.cgi", timeout=2) as response:
                self.assertEqual(response.headers["Livescope-Status"], "0")
                text = response.read().decode()
            self.assertIn("s.hardware:=Canon CR-N500", text)
            self.assertIn("c.1.pan:=0", text)

    def test_continuous_move_requires_an_explicit_stop(self):
        with CameraSimulator(clock="manual") as camera:
            urlopen(camera.url + "/-wvhttp-01-/control.cgi?pan=right&pan.speed=100", timeout=2).close()
            urlopen(Request(camera.url + "/__rig/advance", data=b'{"seconds":2}',
                            headers={"Content-Type": "application/json"}), timeout=2).close()
            with urlopen(camera.url + "/-wvhttp-01-/info.cgi", timeout=2) as response:
                self.assertIn("c.1.pan:=200", response.read().decode())
            urlopen(camera.url + "/-wvhttp-01-/control.cgi?pan=stop", timeout=2).close()
            urlopen(Request(camera.url + "/__rig/advance", data=b'{"seconds":3}',
                            headers={"Content-Type": "application/json"}), timeout=2).close()
            with urlopen(camera.url + "/-wvhttp-01-/info.cgi", timeout=2) as response:
                text = response.read().decode()
            self.assertIn("c.1.pan:=200", text)
            self.assertIn("c.1.pan.status:=0", text)

    def test_controller_stores_and_recalls_a_named_preset_over_http(self):
        from camera_rig.controller import Controller
        with CameraSimulator(clock="manual") as camera, Controller(camera.url) as controller:
            controller.command("control.cgi", {"pan": "900", "tilt": "-200", "zoom": "4000"}).require_ok()
            controller.preset_store(7, "Lectern α").require_ok()
            controller.command("control.cgi", {"pan": "-500", "tilt": "100"}).require_ok()
            controller.preset_recall(7).require_ok()
            info = controller.info().require_ok().fields
            self.assertEqual(info["c.1.pan"], "900")
            self.assertEqual(info["c.1.tilt"], "-200")
            self.assertEqual(info["p.7.name.utf8"], "Lectern α")

    def test_controller_records_prepares_and_plays_a_trace(self):
        from camera_rig.controller import Controller
        with CameraSimulator(clock="manual") as camera, Controller(camera.url) as controller:
            controller.trace_record("start", 2, "Stage walk").require_ok()
            controller.move("right", "stop", 100).require_ok()
            controller.admin("advance", {"seconds": 2})
            controller.focus("one_shot").require_ok()
            controller.move().require_ok()
            controller.trace_record("stop").require_ok()
            controller.command("control.cgi", {"pan": "-900"}).require_ok()
            controller.trace_play("prepare", 2).require_ok()
            self.assertEqual(controller.info().require_ok().fields["c.1.pan"], "0")
            controller.trace_play("start", 2).require_ok()
            controller.admin("advance", {"seconds": 2})
            info = controller.info().require_ok().fields
            self.assertEqual(info["c.1.pan"], "200")
            self.assertEqual(info["t.status"], "idle")
            self.assertEqual(info["t.2.recorded"], "on")

    def test_rejected_multi_axis_command_does_not_partially_move_camera(self):
        from camera_rig.controller import Controller
        with CameraSimulator(clock="manual") as camera, Controller(camera.url) as controller:
            reply = controller.command("control.cgi", {"pan": "right", "tilt": "invalid"})
            self.assertEqual(reply.livescope, "403")
            controller.admin("advance", {"seconds": 1})
            self.assertEqual(controller.info().require_ok().fields["c.1.pan"], "0")

    def test_exclusive_session_profile_reproduces_control_contention(self):
        from camera_rig.controller import Controller
        with CameraSimulator(clock="manual", ownership="exclusive") as camera:
            with Controller(camera.url) as hardware, Controller(camera.url, actor="software") as software:
                hardware.connect().require_ok()
                software.connect().require_ok()
                self.assertEqual(hardware.move("right").livescope, "301")
                hardware.claim().require_ok()
                self.assertEqual(software.move("left").livescope, "301")
                hardware.move("right").require_ok()
                hardware.release().require_ok()
                self.assertEqual(hardware.info().livescope, "0")

    def test_one_shot_camera_fault_is_observable_and_does_not_apply_the_command(self):
        from camera_rig.controller import Controller
        with CameraSimulator(clock="manual") as camera, Controller(camera.url) as controller:
            controller.admin("fault", {"mode": "livescope", "code": 408, "endpoint": "control.cgi"})
            self.assertEqual(controller.move("right").livescope, "408")
            controller.admin("advance", {"seconds": 1})
            self.assertEqual(controller.info().require_ok().fields["c.1.pan"], "0")
            controller.move("right").require_ok()
            events = controller.admin("events")["events"]
            moves = [e for e in events if e["endpoint"] == "control.cgi"]
            self.assertEqual([e["livescope"] for e in moves], ["408", "0"])

    def test_scenario_runner_exercises_a_network_target_and_reports_evidence(self):
        from camera_rig.scenarios import verify
        with CameraSimulator(clock="manual") as camera:
            report = verify(camera.url, camera.url)
        self.assertTrue(report["passed"], report)
        self.assertEqual(report["mode"], "direct_simulator_baseline")
        self.assertTrue(report["checks"])
        self.assertEqual(report["tracking_handoff_verified"], False)

    def test_standalone_cli_selftest_saves_a_machine_readable_report(self):
        launcher = Path(__file__).resolve().parents[2] / "camera-rig.py"
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "report.json"
            result = subprocess.run([sys.executable, str(launcher), "selftest", "--output", str(output)],
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            report = json.loads(output.read_text())
            self.assertTrue(report["passed"])
            self.assertEqual(report["tracking_handoff_verified"], False)

    def test_lowest_zoom_speed_is_a_valid_held_command(self):
        from camera_rig.controller import Controller
        with CameraSimulator(clock="manual") as camera, Controller(camera.url) as controller:
            controller.zoom("tele", 0).require_ok()
            controller.admin("advance", {"seconds": 1})
            self.assertEqual(controller.admin("state")["commanded_axes"], ["zoom"])
            self.assertLess(int(controller.info().require_ok().fields["c.1.zoom"]), 4000)

    def test_unsupported_preset_operation_cannot_silently_store_a_preset(self):
        from camera_rig.controller import Controller
        with CameraSimulator(clock="manual") as camera, Controller(camera.url) as controller:
            response = controller.command("preset/set", {"p": 1, "cmd": "bogus"}, method="POST")
            self.assertEqual(response.livescope, "403")
            self.assertEqual(controller.preset_recall(1).livescope, "403")

    def test_repeated_verification_releases_controller_sessions(self):
        from camera_rig.controller import Controller
        from camera_rig.scenarios import verify
        with CameraSimulator(clock="manual") as camera, Controller(camera.url) as admin:
            for _ in range(6):
                report = verify(camera.url, camera.url)
                self.assertTrue(report["passed"], report)
            self.assertEqual(admin.admin("state")["session_count"], 0)

    def test_trace_playback_stop_halts_both_motion_and_focus(self):
        from camera_rig.controller import Controller
        with CameraSimulator(clock="manual") as camera, Controller(camera.url) as controller:
            controller.trace_record("start", 1).require_ok()
            controller.move("right").require_ok()
            controller.focus("far").require_ok()
            controller.admin("advance", {"seconds": 5})
            controller.trace_record("stop").require_ok()
            controller.trace_play("prepare", 1).require_ok()
            controller.trace_play("start", 1).require_ok()
            controller.admin("advance", {"seconds": 1})
            controller.trace_play("stop").require_ok()
            controller.admin("advance", {"seconds": 5})
            info = controller.info().require_ok().fields
            self.assertEqual(info["c.1.pan"], "100")
            self.assertEqual(info["c.1.focus.action"], "stop")
            self.assertEqual(info["t.status"], "idle")


if __name__ == "__main__":
    unittest.main()
