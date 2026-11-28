"""HTTP camera simulator used independently of Churchfront and the bridge."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from collections import deque
import hashlib
import json
from pathlib import Path
import socket
import threading
import time
import uuid
from urllib.parse import parse_qsl, urlsplit

from .model import CameraModel, ProtocolError


class CameraSimulator:
    def __init__(self, *, clock="manual", port=0, ownership="documented", preview_image=None):
        self.clock = clock
        self.port = port
        self.server = None
        self.thread = None
        self.model = CameraModel(clock, ownership)
        self.lock = threading.RLock()
        self.events = deque(maxlen=2000)
        self.sequence = 0
        self.faults = []
        self.run_id = uuid.uuid4().hex
        self.preview = None
        if preview_image is not None:
            path = Path(preview_image)
            if not path.is_file() or not 4 <= path.stat().st_size <= 2_097_152:
                raise ValueError("preview image must be a regular JPEG file of at most 2 MiB")
            with path.open("rb") as stream:
                self.preview = stream.read(2_097_153)
            if len(self.preview) > 2_097_152:
                raise ValueError("preview image exceeds 2 MiB")
            if not self.preview.startswith(b"\xff\xd8") or not self.preview.endswith(b"\xff\xd9"):
                raise ValueError("preview image must contain a JPEG")
        self.preview_stop = threading.Event()
        self.preview_slots = threading.BoundedSemaphore(4)

    def record(self, endpoint, parameters, method, actor, status, livescope, fingerprint, fault=None):
        allowed = {"pan", "tilt", "zoom", "pan.speed", "tilt.speed", "zoom.speed",
                   "focus", "focus.action", "p", "t", "cmd", "all", "name", "item", "s.priority"}
        with self.lock:
            self.sequence += 1
            self.events.append({"sequence": self.sequence, "time": time.time(),
                                "elapsed": self.model.elapsed, "endpoint": endpoint,
                                "method": method, "actor": actor,
                                "parameters": {k: v for k, v in parameters.items()
                                               if k.removeprefix("c.1.") in allowed},
                                "http_status": status, "livescope": str(livescope) if livescope is not None else None,
                                "fault": fault,
                                "session_fingerprint": hashlib.sha256(parameters["s"].encode()).hexdigest()[:16]
                                    if parameters.get("s") else None,
                                "wire_fingerprint": fingerprint})

    def admin(self, method, path, data):
        with self.lock:
            self.model.tick()
            if path == "meta" and method == "GET":
                return {"kind": "canon-camera-test-rig", "version": 1, "run_id": self.run_id,
                        "clock": self.clock, "ownership": self.model.ownership,
                        "preview_enabled": self.preview is not None}
            if path == "state" and method == "GET":
                return {"info": self.model.info(), "commanded_axes":
                        [axis for axis, value in self.model.velocity.items() if value],
                        "session_count": len(self.model.sessions), "clock": self.clock,
                        "elapsed": self.model.elapsed}
            if path == "events" and method == "GET":
                return {"events": list(self.events), "last_sequence": self.sequence,
                        "retained": len(self.events)}
            if path == "advance" and method == "POST":
                if self.clock != "manual":
                    raise ValueError("advance requires manual clock")
                self.model.step(float(data["seconds"]))
                return {"elapsed": self.model.elapsed}
            if path == "expire-sessions" and method == "POST":
                # Camera control privilege expires independently of commanded motion.
                self.model.sessions.clear()
                self.model.owner = None
                return {"ok": True}
            if path == "reset" and method == "POST":
                old_sessions, old_owner = self.model.sessions, self.model.owner
                self.model = CameraModel(self.clock, self.model.ownership)
                if data.get("keep_sessions"):
                    self.model.sessions, self.model.owner = old_sessions, old_owner
                self.faults.clear()
                self.events.clear()
                return {"ok": True}
            if path == "fault" and method == "POST":
                mode = data.get("mode")
                if mode not in ("delay", "delay_after", "disconnect", "http", "livescope", "malformed", "stream"):
                    raise ValueError("unknown fault mode")
                endpoint = data.get("endpoint", "*")
                if endpoint not in ("*", "info.cgi", "control.cgi", "preset/set", "trace/set", "trace/control",
                                    "open.cgi", "claim.cgi", "close.cgi", "yield.cgi"):
                    raise ValueError("unknown fault endpoint")
                count = int(data.get("count", 1))
                seconds = float(data.get("seconds", 0.1))
                code = int(data.get("code", 503 if mode == "http" else 408))
                if not 1 <= count <= 20 or not 0 <= seconds <= 3 or not 100 <= code <= 599:
                    raise ValueError("fault limits exceeded")
                if mode == "http" and code < 400:
                    raise ValueError("HTTP fault code must be between 400 and 599")
                if len(self.faults) >= 32:
                    raise ValueError("fault queue full")
                self.faults.append({"mode": mode, "endpoint": endpoint,
                                    "count": count, "seconds": seconds, "code": code})
                return {"ok": True}
        raise ValueError("unknown rig operation")

    def take_fault(self, endpoint):
        with self.lock:
            for index, fault in enumerate(self.faults):
                if fault["endpoint"] in ("*", endpoint):
                    result = fault.copy()
                    fault["count"] -= 1
                    if fault["count"] == 0:
                        self.faults.pop(index)
                    return result
        return None

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def __enter__(self):
        simulator = self
        self.preview_stop.clear()

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def reply(self, status, body, *, content_type="text/plain;charset=utf-8", livescope="0"):
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Livescope-Status", str(livescope))
                if self.close_connection:
                    self.send_header("Connection", "close")
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def handle_request(self):
                endpoint, parameters, fingerprint = "unparsed", {}, ""
                actor = self.headers.get("User-Agent", "").removeprefix("CameraTestRig/")
                if actor not in ("controller", "software"):
                    actor = "unknown"
                try:
                    size = int(self.headers.get("Content-Length", "0"))
                    if not 0 <= size <= 65536 or self.headers.get("Transfer-Encoding"):
                        raise ValueError("unsupported request framing")
                    body = self.rfile.read(size)
                    parsed = urlsplit(self.path)
                    if len(body) != size:
                        raise ValueError("incomplete request")
                    if parsed.path.startswith("/__rig/"):
                        data = json.loads(body) if body else {}
                        if not isinstance(data, dict):
                            raise ValueError("expected JSON object")
                        result = simulator.admin(self.command, parsed.path.removeprefix("/__rig/"), data)
                        self.reply(200, json.dumps(result).encode(), content_type="application/json")
                        return
                    if not parsed.path.startswith("/-wvhttp-01-/"):
                        self.reply(404, b"Not found\n", livescope="401")
                        return
                    endpoint = parsed.path.removeprefix("/-wvhttp-01-/")
                    fingerprint = hashlib.sha256(self.path.encode() + b"\x00" + body).hexdigest()
                    if endpoint == "video.cgi" and simulator.preview is not None:
                        self.preview(actor, fingerprint)
                        return
                    pairs = parse_qsl(parsed.query, keep_blank_values=True)
                    if body:
                        pairs += parse_qsl(body.decode("ascii"), keep_blank_values=True)
                    parameters = {}
                    for key, value in pairs:
                        if key in parameters:
                            if endpoint != "info.cgi" or key != "item":
                                raise ProtocolError(403, "duplicate parameter")
                            value = parameters[key] + "," + value
                        parameters[key] = value
                    fault = simulator.take_fault(endpoint)
                    if fault:
                        mode = fault["mode"]
                        if mode == "delay":
                            time.sleep(fault["seconds"])
                        elif mode in ("http", "livescope", "disconnect", "malformed"):
                            status, scope = (fault["code"], "0") if mode == "http" else (200, str(fault["code"]))
                            if mode in ("disconnect", "malformed"):
                                status, scope = None, None
                            simulator.record(endpoint, parameters, self.command, actor, status, scope, fingerprint, mode)
                            if mode == "disconnect":
                                self.close_connection = True
                                self.connection.shutdown(socket.SHUT_RDWR)
                            elif mode == "malformed":
                                self.wfile.write(b"NOT-HTTP\r\n\r\n")
                                self.close_connection = True
                            else:
                                self.reply(status, b"Injected test failure\n", livescope=scope)
                            return
                    with simulator.lock:
                        simulator.model.tick()
                        if parsed.path.startswith("/-wvhttp-01-/") and endpoint in ("open.cgi", "claim.cgi", "yield.cgi", "close.cgi"):
                            result = simulator.model.session(endpoint, parameters)
                            if endpoint == "open.cgi":
                                result["s.origin"] = simulator.url.removeprefix("http://")
                        elif parsed.path == "/-wvhttp-01-/info.cgi":
                            simulator.model.authorize(parameters)
                            result = simulator.model.info()
                            if "s" in parameters:
                                result["s.control"] = "enabled" if simulator.model.owner == parameters["s"] else "waiting"
                            if parameters.get("item"):
                                items = parameters["item"].split(",")
                                result = {key: value for key, value in result.items() if key in items}
                        elif parsed.path == "/-wvhttp-01-/control.cgi":
                            simulator.model.authorize(parameters, write=True)
                            result = simulator.model.control(parameters)
                        elif parsed.path == "/-wvhttp-01-/preset/set":
                            simulator.model.authorize(parameters, write=True)
                            result = simulator.model.preset_set(parameters)
                        elif parsed.path == "/-wvhttp-01-/trace/set":
                            simulator.model.authorize(parameters, write=True)
                            result = simulator.model.trace_set(parameters)
                        elif parsed.path == "/-wvhttp-01-/trace/control":
                            simulator.model.authorize(parameters, write=True)
                            result = simulator.model.trace_control(parameters)
                        else:
                            self.reply(404, b"Not found\n", livescope="401")
                            return
                    simulator.record(endpoint, parameters, self.command, actor, 200, "0", fingerprint,
                                     fault["mode"] if fault else None)
                    if fault and fault["mode"] == "delay_after":
                        time.sleep(fault["seconds"])
                    payload = "".join(f"{key}:={value}\n" for key, value in result.items()).encode()
                    if fault and fault["mode"] == "stream":
                        self.send_response(200)
                        self.send_header("Content-Type", "text/plain;charset=utf-8")
                        self.send_header("Livescope-Status", "0")
                        self.send_header("Transfer-Encoding", "chunked")
                        self.end_headers()

                        def chunk(data):
                            self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
                            self.wfile.flush()

                        chunk(payload)
                        time.sleep(fault["seconds"])
                        chunk(b"rig.stream.frame:=2\n")
                        self.wfile.write(b"0\r\n\r\n")
                        self.wfile.flush()
                    else:
                        self.reply(200, payload)
                except ProtocolError as error:
                    simulator.record(endpoint, parameters, self.command, actor, 200, error.status, fingerprint)
                    scope = "501 Unknown Connection ID" if error.status == 501 else error.status
                    self.reply(200, str(error).encode(), livescope=scope)
                except (ValueError, KeyError, TypeError, UnicodeError):
                    self.close_connection = True
                    self.reply(400, b"Invalid request\n", livescope="403")
                except (OSError, TimeoutError):
                    self.close_connection = True

            do_GET = handle_request
            do_POST = handle_request

            def preview(self, actor, fingerprint):
                self.close_connection = True
                if self.command != "GET":
                    self.reply(405, b"Preview requires GET\n", livescope="401")
                    return
                if not simulator.preview_slots.acquire(blocking=False):
                    self.reply(503, b"Preview client limit reached\n", livescope="408")
                    return
                try:
                    # One journal entry per connection, never per frame: the
                    # preview cannot evict command-order evidence at video rate.
                    simulator.record("video.cgi", {}, "GET", actor, 200, "0", fingerprint)
                    self.send_response(200)
                    self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=camera-rig")
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Livescope-Status", "0")
                    self.send_header("Connection", "close")
                    self.end_headers()
                    frame = (b"--camera-rig\r\nContent-Type: image/jpeg\r\nContent-Length: "
                             + str(len(simulator.preview)).encode() + b"\r\n\r\n"
                             + simulator.preview + b"\r\n")
                    while not simulator.preview_stop.is_set():
                        self.wfile.write(frame)
                        self.wfile.flush()
                        simulator.preview_stop.wait(0.1)
                finally:
                    simulator.preview_slots.release()

            def handle(self):
                try:
                    super().handle()
                except (ConnectionError, TimeoutError):
                    # Expected when testing dropped connections and timed-out clients.
                    self.close_connection = True

            def setup(self):
                super().setup()
                self.connection.settimeout(3)

        self.server = ThreadingHTTPServer(("127.0.0.1", self.port), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(
            target=self.server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.preview_stop.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
