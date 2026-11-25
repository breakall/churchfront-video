"""Diagnostic evidence from the actual helper, using only loopback fixtures.

Run after building the helper:
  CAMERA_BRIDGE_TEST_BINARY=/absolute/path/to/camera-control-bridge \
    PYTHONPATH=Tools python3 -m unittest discover -s Tools/camera_rig/tests \
    -p test_bridge_diagnostics.py -v

The environment variable is deliberately required: ordinary rig unit tests do
not silently build a helper or connect to any installed camera configuration.
"""

from contextlib import contextmanager
import json
import os
import socket
import socketserver
import tempfile
import threading
import time
import unittest

from camera_rig.bridge_scenarios import AppClient, BridgeProcess
from camera_rig.camera import CameraSimulator
from camera_rig.controller import Controller, loopback_url


BINARY = os.environ.get("CAMERA_BRIDGE_TEST_BINARY")


@contextmanager
def raw_camera(response, *, before_response=None):
    """Send exactly the supplied bytes, keeping fixture secrets out of logs."""
    requests = []

    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.settimeout(2)
            data = b""
            while b"\r\n\r\n" not in data:
                block = self.request.recv(65536)
                if not block:
                    return
                data += block
            requests.append(data)
            endpoint = data.split(b" ", 2)[1].split(b"?", 1)[0].split(b"/")[-1]
            if endpoint in (b"open.cgi", b"claim.cgi", b"close.cgi"):
                body = {b"open.cgi": b"s:=RIG_UPSTREAM_SESSION\r\n",
                        b"claim.cgi": b"s.control:=enabled:20000\r\n", b"close.cgi": b""}[endpoint]
                self.request.sendall(b"HTTP/1.1 200 OK\r\nLivescope-Status: 0\r\nContent-Length: " +
                                     str(len(body)).encode() + b"\r\n\r\n" + body)
                return
            if before_response is not None:
                before_response.wait(timeout=3)
            try:
                self.request.sendall(response)
            except (BrokenPipeError, ConnectionResetError):
                pass  # A disconnect test deliberately closes the downstream.

    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    server = Server(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever,
                              kwargs={"poll_interval": 0.01}, daemon=True)
    thread.start()
    try:
        yield "http://127.0.0.1:%d" % server.server_address[1], requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def exchange(target, request):
    host, port = loopback_url(target)
    with socket.create_connection((host, port), timeout=3) as connection:
        connection.sendall(request)
        data = b""
        while True:
            block = connection.recv(65536)
            if not block:
                return data
            data += block


def events_when(bridge, predicate):
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        content = (bridge.diagnostics_file.read_text()
                   if bridge.diagnostics_file.exists() else "")
        try:
            events = [json.loads(line) for line in content.splitlines()]
        except json.JSONDecodeError:
            # Logger appends asynchronously. Wait for a complete JSON line.
            time.sleep(0.01)
            continue
        if predicate(events):
            return events, content
        time.sleep(0.01)
    raise AssertionError("Expected diagnostic event was not written: %s" % content)


@unittest.skipUnless(BINARY, "set CAMERA_BRIDGE_TEST_BINARY to test the real helper")
class BridgeDiagnosticsTests(unittest.TestCase):
    def test_sessionless_discovery_reply_remains_byte_exact(self):
        body = b"c.1.focus:=auto\n\n"
        response = (b"HTTP/1.1 200 OK\r\nServer: vb\r\nlivescope-status: 0\r\n"
                    b"content-type: text/plain; charset=utf-8\r\nContent-Length: " +
                    str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
        with tempfile.TemporaryDirectory() as directory, raw_camera(response) as (camera, _):
            with BridgeProcess(BINARY, camera, directory) as bridge:
                request = b"GET /-wvhttp-01-/info.cgi?item=c.1.focus HTTP/1.1\r\nHost: localhost\r\n\r\n"
                self.assertEqual(exchange(bridge.controller_url, request), response)

    def test_information_response_uses_virtual_session_and_secrets_are_not_logged(self):
        secret = "PRIVATE_CAMERA_SESSION_5fd7b8"
        digest = "PRIVATE_DIGEST_CREDENTIAL_70b3"
        cookie = "PRIVATE_COOKIE_47cf"
        body = ("s.control:=enabled:20000\r\ns:=" + secret +
                "\r\ns.origin:=http://private-origin.example:1234\r\n" +
                "password:=PRIVATE_BODY_PASSWORD_85fa\r\n").encode()
        response = (b"HTTP/1.1 200 OK\r\nLivescope-Status: 0\r\n"
                    b"Content-Type: text/plain; charset=utf-8\r\n"
                    b"Set-Cookie: " + cookie.encode() + b"\r\nContent-Length: " +
                    str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
        with tempfile.TemporaryDirectory() as directory, raw_camera(response) as (camera, requests):
            with BridgeProcess(BINARY, camera, directory) as bridge:
                with Controller(bridge.controller_url) as hardware:
                    hardware.connect().require_ok()
                    virtual_session = hardware.session
                request = ("GET /-wvhttp-01-/info.cgi?s=" + virtual_session +
                           "&password=PRIVATE_QUERY_PASSWORD_02f6 HTTP/1.1\r\nHost: localhost\r\n" +
                           "Authorization: Digest response=\"" + digest + "\"\r\n" +
                           "Cookie: " + cookie + "\r\nConnection: close\r\n\r\n").encode()
                result = exchange(bridge.controller_url, request)
                self.assertIn(virtual_session.encode(), result)
                self.assertIn(bridge.controller_url.removeprefix("http://").encode(), result)
                self.assertNotIn(secret.encode(), result)
                self.assertNotIn(b"private-origin.example", result)
                info_requests = [item for item in requests if b"/info.cgi" in item]
                self.assertTrue(info_requests)
                self.assertIn(digest.encode(), info_requests[-1], "Authentication header reaches the camera")
                self.assertNotIn(virtual_session.encode(), info_requests[-1])
                sessionless = request.replace(("s=" + virtual_session + "&").encode(), b"")
                public_info = exchange(bridge.controller_url, sessionless)
                self.assertNotIn(secret.encode(), public_info)
                self.assertNotIn(virtual_session.encode(), public_info)
                self.assertNotIn(b"private-origin.example", public_info)
                events, content = events_when(bridge, lambda es: any(
                    e.get("decision") == "information_stream_finished" and
                    e["details"].get("downstreamBytes") == len(public_info) for e in es))
                for value in (secret, virtual_session, digest, cookie, "PRIVATE_BODY_PASSWORD_85fa",
                              "PRIVATE_QUERY_PASSWORD_02f6", "private-origin.example", bridge.token):
                    self.assertNotIn(value, content)
                self.assertTrue(all(e.get("schemaVersion") == 2 for e in events))
                snapshot = next(e for e in events if e.get("decision") == "information_snapshot")
                self.assertEqual(snapshot["status"], 200)
                self.assertEqual(snapshot["livescope"], "0")
                self.assertEqual(snapshot["details"]["controlState"], "enabled")
                self.assertEqual(snapshot["details"]["originRelation"], "other")
                self.assertEqual(snapshot["details"]["authScheme"], "digest")
                self.assertEqual(snapshot["details"]["sessionPresent"], False)
                finished = next(e for e in events if e.get("decision") == "information_stream_finished"
                                and e["details"].get("downstreamBytes") == len(public_info))
                self.assertEqual(finished["reason"], "upstream_eof")
                self.assertEqual(finished["details"]["upstreamBytes"], len(response))
                self.assertEqual(finished["details"]["downstreamBytes"], len(public_info))
                self.assertGreaterEqual(finished["details"]["firstByteMs"], 0)

    def test_camera_authentication_failure_is_visible_without_challenge_secrets(self):
        challenge = "PRIVATE_CHALLENGE_NONCE_1ae7"
        response = ("HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Digest nonce=\"" +
                    challenge + "\"\r\nLivescope-Status: 501 PRIVATE_HEADER_TEXT_50fe\r\n" +
                    "Content-Length: 0\r\nConnection: close\r\n\r\n").encode()
        with tempfile.TemporaryDirectory() as directory, raw_camera(response) as (camera, _):
            with BridgeProcess(BINARY, camera, directory) as bridge:
                result = exchange(bridge.controller_url,
                                  b"GET /-wvhttp-01-/info.cgi HTTP/1.1\r\nHost: localhost\r\n\r\n")
                self.assertTrue(result.startswith(b"HTTP/1.1 401 "))
                self.assertIn(b'www-authenticate: digest nonce="' + challenge.lower().encode() + b'"', result.lower())
                self.assertIn(b"livescope-status: 501 ", result.lower())
                events, content = events_when(bridge, lambda es: any(
                    e.get("decision") == "information_stream_finished" for e in es))
                event = next(e for e in events if e.get("decision") == "information_response")
                self.assertEqual(event["status"], 401)
                self.assertEqual(event["livescope"], "501")
                self.assertNotIn(challenge, content)
                self.assertNotIn("PRIVATE_HEADER_TEXT_50fe", content)

    def test_virtual_session_diagnostics_do_not_log_either_session(self):
        with tempfile.TemporaryDirectory() as directory, CameraSimulator() as camera:
            with BridgeProcess(BINARY, camera.url, directory) as bridge, Controller(bridge.controller_url) as hardware:
                hardware.connect().require_ok()
                downstream = hardware.session
                hardware.move().require_ok()
                events, content = events_when(bridge, lambda es: any(
                    e.get("decision") == "forwarded" and e.get("endpoint", "").endswith("control.cgi") for e in es))
                with camera.lock:
                    upstream_tokens = list(camera.model.sessions)
                self.assertTrue(upstream_tokens)
                self.assertNotIn(downstream, upstream_tokens)
                for value in [downstream, *upstream_tokens]:
                    self.assertNotIn(value, content)
                self.assertTrue(any(e.get("origin") == "controller" for e in events))


    def test_listener_rejections_are_classified_without_logging_input(self):
        secret = "PRIVATE_REQUEST_SECRET_997f"
        cases = (
            ("HEAD /private/" + secret + " HTTP/1.1\r\nHost: localhost\r\n\r\n",
             "invalid_request_line"),
            ("POST /-wvhttp-01-/control.cgi?password=" + secret +
             " HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
             "unsupported_framing"),
            ("GET /-wvhttp-01-/info.cgi HTTP/1.1\r\nHost: localhost\r\n" +
             "Authorization: " + secret + "\r\nHost: " + secret + "\r\n\r\n",
             "duplicate_header"),
            ("GET /-wvhttp-01-/info.cgi HTTP/1.1\r\nHost: localhost\r\n\r\n" +
             "GET /private/" + secret + " HTTP/1.1\r\nHost: localhost\r\n\r\n",
             "pipelining"),
        )
        with tempfile.TemporaryDirectory() as directory, CameraSimulator(clock="manual") as camera:
            with BridgeProcess(BINARY, camera.url, directory) as bridge:
                for request, reason in cases:
                    with self.subTest(reason=reason):
                        reply = exchange(bridge.controller_url, request.encode())
                        self.assertGreaterEqual(int(reply.split(b" ", 2)[1]), 400)
                        events, content = events_when(bridge, lambda es: any(
                            e.get("reason") == reason for e in es))
                        self.assertTrue(any(e.get("reason") == reason for e in events), events)
                        self.assertNotIn(secret, content)
                self.assertIsNone(bridge.process.poll())

    def test_controller_half_close_before_camera_headers_is_distinguished(self):
        release = threading.Event()
        response = b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        with tempfile.TemporaryDirectory() as directory, raw_camera(
                response, before_response=release) as (camera, _):
            try:
                with BridgeProcess(BINARY, camera, directory) as bridge:
                    host, port = loopback_url(bridge.controller_url)
                    with socket.create_connection((host, port), timeout=3) as connection:
                        connection.sendall(b"GET /-wvhttp-01-/info.cgi HTTP/1.1\r\nHost: localhost\r\n\r\n")
                        connection.shutdown(socket.SHUT_WR)
                        events, _ = events_when(bridge, lambda es: any(
                            e.get("decision") == "information_stream_finished" for e in es))
                    event = next(e for e in events if e.get("decision") == "information_stream_finished")
                    self.assertEqual(event["reason"], "downstream_eof")
                    self.assertFalse(event["details"]["sentHeaders"])
                    self.assertEqual(event["details"]["upstreamBytes"], 0)
            finally:
                release.set()

    def test_malformed_camera_response_records_a_bounded_close_reason(self):
        secret = "PRIVATE_MALFORMED_CAMERA_BYTES_05d1"
        with tempfile.TemporaryDirectory() as directory, raw_camera(secret.encode()) as (camera, _):
            with BridgeProcess(BINARY, camera, directory) as bridge:
                reply = exchange(bridge.controller_url,
                                 b"GET /-wvhttp-01-/info.cgi HTTP/1.1\r\nHost: localhost\r\n\r\n")
                self.assertEqual(int(reply.split(b" ", 2)[1]), 502)
                events, content = events_when(bridge, lambda es: any(
                    e.get("reason") == "malformed_headers" for e in es))
                finished = next(e for e in events if e.get("reason") == "malformed_headers")
                self.assertFalse(finished["details"]["sentHeaders"])
                self.assertNotIn(secret, content)

    def test_recovery_reason_explains_app_block_without_bypassing_it(self):
        with tempfile.TemporaryDirectory() as directory, CameraSimulator(clock="manual") as camera:
            with BridgeProcess(BINARY, camera.url, directory):
                pass  # A deliberate restart leaves the existing recovery marker.
            with BridgeProcess(BINARY, camera.url, directory) as bridge:
                app = AppClient(bridge.app_url, bridge.token)
                lease = app.connect()
                before = app.status()
                self.assertTrue(before["recoveryRequired"])
                reply = app.command(lease, {"pan": "left"}, purpose="manualMove")
                self.assertEqual(reply.status, 409)
                after = app.status()
                self.assertTrue(after["recoveryRequired"])
                self.assertEqual(before["generation"], after["generation"])
                events, content = events_when(bridge, lambda es: any(
                    e.get("reason") == "recovery_required" for e in es))
                blocked = next(e for e in events if e.get("reason") == "recovery_required")
                self.assertEqual(blocked["status"], 409)
                self.assertEqual(blocked["origin"], "app")
                self.assertNotIn(bridge.token, content)
