import http.client
from pathlib import Path
import unittest
import tempfile

from camera_rig.camera import CameraSimulator
from camera_rig.controller import Controller


PHOTO = Path(__file__).resolve().parents[1] / "fixtures/public-domain-person.jpg"


class PreviewTests(unittest.TestCase):
    def test_preview_rejects_missing_invalid_and_oversized_files_before_listening(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "preview.jpg"
            with self.assertRaises(ValueError):
                CameraSimulator(preview_image=path)
            path.write_bytes(b"not a JPEG")
            with self.assertRaises(ValueError):
                CameraSimulator(preview_image=path)
            with path.open("wb") as stream:
                stream.truncate(2_097_153)
            with self.assertRaises(ValueError):
                CameraSimulator(preview_image=path)

    def test_preview_is_opt_in_and_streams_repeated_exact_jpeg_frames(self):
        with CameraSimulator() as camera, Controller(camera.url) as controller:
            self.assertEqual(controller.request("/-wvhttp-01-/video.cgi").status, 404)
        expected = PHOTO.read_bytes()
        with CameraSimulator(preview_image=PHOTO) as camera, Controller(camera.url) as controller:
            connection = http.client.HTTPConnection("127.0.0.1", camera.server.server_port, timeout=2)
            try:
                connection.request("GET", "/-wvhttp-01-/video.cgi")
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertIn("multipart/x-mixed-replace", response.getheader("Content-Type"))
                for _ in range(2):
                    self.assertEqual(response.readline(), b"--camera-rig\r\n")
                    self.assertEqual(response.readline(), b"Content-Type: image/jpeg\r\n")
                    length = int(response.readline().split(b":", 1)[1])
                    self.assertEqual(response.readline(), b"\r\n")
                    self.assertEqual(response.read(length), expected)
                    self.assertEqual(response.read(2), b"\r\n")
                # An open preview must not block independent camera-control traffic.
                controller.move("right").require_ok()
                controller.move().require_ok()
                events = controller.admin("events")["events"]
                self.assertEqual(len([e for e in events if e["endpoint"] == "video.cgi"]), 1)
            finally:
                connection.close()


if __name__ == "__main__":
    unittest.main()
