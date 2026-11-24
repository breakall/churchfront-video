import http.client
import json
import unittest

from camera_rig.camera import CameraSimulator
from camera_rig.controller import Controller


class FailureTests(unittest.TestCase):
    def test_http_errors_are_not_successful_commands_and_the_camera_recovers(self):
        with CameraSimulator(clock="manual") as camera, Controller(camera.url) as controller:
            controller.admin("fault", {"mode": "http", "code": 503, "endpoint": "control.cgi"})
            reply = controller.move("right")
            self.assertEqual(reply.status, 503)
            with self.assertRaises(RuntimeError):
                reply.require_ok()
            self.assertEqual(controller.admin("state")["commanded_axes"], [])
            controller.move("right").require_ok()

    def test_disconnect_and_malformed_response_do_not_retry_or_move_the_camera(self):
        for mode in ("disconnect", "malformed"):
            with self.subTest(mode=mode), CameraSimulator(clock="manual") as camera:
                with Controller(camera.url) as controller:
                    controller.admin("fault", {"mode": mode, "endpoint": "control.cgi"})
                    with self.assertRaises(http.client.HTTPException):
                        controller.move("right")
                    self.assertEqual(controller.admin("state")["commanded_axes"], [])
                    events = controller.admin("events")["events"]
                    self.assertEqual(len([e for e in events if e["endpoint"] == "control.cgi"]), 1)
                    self.assertEqual(events[0]["fault"], mode)
                    self.assertIsNone(events[0]["http_status"])
                    controller.move("right").require_ok()

    def test_timeout_after_application_is_ambiguous_and_does_not_retry(self):
        with CameraSimulator(clock="manual") as camera, Controller(camera.url) as admin:
            admin.admin("fault", {"mode": "delay_after", "seconds": 0.25, "endpoint": "control.cgi"})
            with Controller(camera.url, timeout=0.05) as controller:
                with self.assertRaises(TimeoutError):
                    controller.move("right")
                self.assertEqual(admin.admin("state")["commanded_axes"], ["pan"])
                events = admin.admin("events")["events"]
                self.assertEqual(len([e for e in events if e["endpoint"] == "control.cgi"]), 1)
                controller.move().require_ok()
                self.assertEqual(admin.admin("state")["commanded_axes"], [])

    def test_limit_status_does_not_falsely_mean_a_held_joystick_was_released(self):
        with CameraSimulator(clock="manual") as camera, Controller(camera.url) as controller:
            controller.move("right", speed=10000).require_ok()
            controller.admin("advance", {"seconds": 20})
            self.assertEqual(controller.info().require_ok().fields["c.1.pan.status"], "0")
            self.assertEqual(controller.admin("state")["commanded_axes"], ["pan"])
            controller.move().require_ok()
            self.assertEqual(controller.admin("state")["commanded_axes"], [])

    def test_request_history_redacts_session_ids_and_bounds_memory(self):
        with CameraSimulator(clock="manual") as camera, Controller(camera.url) as controller:
            controller.connect().require_ok()
            token = controller.session
            for _ in range(2010):
                controller.info().require_ok()
            journal = controller.admin("events")
            self.assertEqual(journal["retained"], 2000)
            self.assertNotIn(token, json.dumps(journal))

    def test_rejects_duplicate_parameters_without_partial_mutation(self):
        with CameraSimulator(clock="manual") as camera, Controller(camera.url) as controller:
            reply = controller.request("/-wvhttp-01-/control.cgi?pan=right&pan=left")
            self.assertEqual(reply.livescope, "403")
            self.assertEqual(controller.admin("state")["commanded_axes"], [])
            controller.move("left").require_ok()

    def test_invalid_admin_data_cannot_corrupt_the_clock(self):
        with CameraSimulator(clock="manual") as camera, Controller(camera.url) as controller:
            for value in (-1, float("nan"), float("inf"), 3601):
                with self.subTest(value=value), self.assertRaises(RuntimeError):
                    controller.admin("advance", {"seconds": value})
            self.assertEqual(controller.admin("state")["elapsed"], 0)

    def test_accidental_real_device_targets_are_rejected(self):
        for url in ("http://192.168.1.20", "http://example.com", "https://127.0.0.1",
                    "http://user:password@127.0.0.1", "http://127.0.0.1/something"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                Controller(url)

    def test_fault_api_rejects_informational_http_statuses_that_cannot_complete_a_response(self):
        with CameraSimulator(clock="manual") as camera, Controller(camera.url) as controller:
            with self.assertRaises(RuntimeError):
                controller.admin("fault", {"mode": "http", "code": 100})
            controller.move("right").require_ok()
