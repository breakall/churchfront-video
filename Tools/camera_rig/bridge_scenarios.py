"""Black-box checks against a separately launched, actual bridge executable.

The helper's public controller and authenticated app listeners are the only
bridge interfaces used here. Camera evidence comes from the standalone rig.
"""

from datetime import datetime, timezone
import hashlib
import http.client
import json
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import threading
import time

from .camera import CameraSimulator
from .controller import Controller, Reply, loopback_url
from .scenarios import equal, verify


class BridgeProcess:
    """Own just the helper process started for one isolated verification run."""

    def __init__(self, binary, camera_url, directory, *, diagnostics=True, extra_args=(), diagnostics_directory=False, config_file=False):
        self.binary = Path(binary).resolve()
        if not self.binary.is_file():
            raise ValueError("bridge executable does not exist; build it before running bridge-test")
        loopback_url(camera_url)
        self.camera_url = camera_url
        self.directory = Path(directory)
        self.token = secrets.token_urlsafe(32)
        self.token_file = self.directory / "app-token"
        self.ready_file = self.directory / "ready.json"
        self.diagnostics_file = self.directory / "diagnostics.jsonl"
        self.diagnostics_destination = self.directory if diagnostics_directory else self.diagnostics_file
        self.diagnostics = diagnostics
        self.process = None
        self.extra_args = list(extra_args)
        self.config_file = self.directory / "helper.json" if config_file else None

    def __enter__(self):
        if self.token_file.exists():
            self.token = self.token_file.read_text()
        else:
            self.token_file.write_text(self.token)
            self.token_file.chmod(0o600)
        self.ready_file.unlink(missing_ok=True)
        command = [str(self.binary), "--camera-url", self.camera_url,
                   "--listen-host", "127.0.0.1", "--controller-port", "0", "--app-port", "0",
                   "--controller-address", "127.0.0.1", "--token-file", str(self.token_file),
                   "--ready-file", str(self.ready_file), "--diagnostics-file", str(self.diagnostics_destination)]
        if not self.diagnostics:
            command.append("--no-diagnostics")
        command += self.extra_args
        if self.config_file:
            if self.extra_args:
                raise ValueError("config file test fixtures use a complete config, without CLI overrides")
            config = {"cameraURL": self.camera_url, "listenHost": "127.0.0.1", "controllerPort": 0,
                      "appPort": 0, "controllerAddress": "127.0.0.1", "tokenFile": str(self.token_file),
                      "readyFile": str(self.ready_file), "diagnosticsFile": str(self.diagnostics_destination),
                      "diagnosticsEnabled": self.diagnostics, "requestTimeout": 2, "leaseTimeout": 3}
            self.config_file.write_text(json.dumps(config))
            command = [str(self.binary), "--config", str(self.config_file)]
        self.stdout = (self.directory / "helper.stdout").open("w+")
        self.stderr = (self.directory / "helper.stderr").open("w+")
        try:
            self.process = subprocess.Popen(command, stdout=self.stdout, stderr=self.stderr)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise RuntimeError(f"bridge exited before ready (exit {self.process.returncode})")
                if self.ready_file.exists():
                    try:
                        ready = json.loads(self.ready_file.read_text())
                    except json.JSONDecodeError:
                        time.sleep(0.01)
                        continue
                    equal(ready["version"], 1, "bridge ready interface version")
                    self.controller_url = ready["controller_url"]
                    self.app_url = ready["app_url"]
                    loopback_url(self.controller_url)
                    loopback_url(self.app_url)
                    return self
                time.sleep(0.01)
            raise TimeoutError("bridge did not publish ready endpoints within 10 seconds")
        except BaseException:
            self.__exit__()
            raise

    def __exit__(self, *_):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.stdout.close()
        self.stderr.close()


class AppClient:
    """Independent HTTP test client, deliberately not the Swift client library."""

    def __init__(self, target, token):
        self.host, self.port = loopback_url(target)
        self.token = token
        self.observations = []

    def request(self, action, data=None, *, token=None, version=1):
        headers = {"Authorization": "Bearer " + (self.token if token is None else token),
                   "Content-Type": "application/json"}
        connection = http.client.HTTPConnection(self.host, self.port, timeout=5)
        try:
            body = json.dumps({**data, "version": version}).encode() if data is not None else None
            connection.request("POST" if data is not None else "GET", "/bridge/" + action,
                               body=body, headers=headers)
            response = connection.getresponse()
            payload = response.read(1048577)
            if len(payload) > 1048576:
                raise ValueError("bridge response exceeded rig limit")
            reply = Reply(response.status, {key.lower(): value for key, value in response.getheaders()}, payload)
            event = {"action": action, "http_status": response.status,
                     "time_monotonic": time.monotonic(), "version": version}
            if data is not None and "generation" in data:
                event["request_generation"] = data["generation"]
            try:
                decoded = json.loads(payload)
                for key in ("generation", "authorized", "heldAxes", "health", "manualTakeover", "diagnosticsEnabled"):
                    if key in decoded:
                        event[key] = decoded[key]
            except (ValueError, TypeError):
                pass
            self.observations.append(event)
            return reply
        finally:
            connection.close()

    def status(self):
        return self.request("status").json()

    def connect(self):
        return self.request("connect", {}).json()

    def current(self, lease):
        return {**lease, "generation": self.status()["generation"]}

    def start(self, lease):
        return self.request("start", lease).json()

    def command(self, lease, parameters, *, purpose="tracking", endpoint="control.cgi"):
        return self.request("command", {**lease, "purpose": purpose,
                                        "parameters": parameters, "endpoint": endpoint, "method": "GET"})


def command_ok(reply):
    envelope = reply.json()
    equal(envelope["status"], 200, "forwarded camera HTTP status")
    equal(envelope["headers"].get("livescope-status"), "0", "forwarded camera protocol status")
    return envelope


def rejection(reply, status=409):
    equal(reply.status, status, "bridge rejection HTTP status")


def camera_writes(admin):
    return [event for event in admin.admin("events")["events"]
            if event["endpoint"] in ("control.cgi", "preset/set", "trace/set", "trace/control")]


def assert_revoked(app, old_lease, admin):
    status = app.status()
    equal(status["authorized"], False, "tracking authorization revoked")
    equal(status["manualTakeover"], True, "physical takeover visible")
    if status["generation"] <= old_lease["generation"]:
        raise AssertionError("takeover must advance the authorization generation")
    before = len(camera_writes(admin))
    rejection(app.command(old_lease, {"pan": "left", "pan.speed": "100"}))
    rejection(app.command(old_lease, {"pan": "stop", "tilt": "stop"}))
    equal(len(camera_writes(admin)), before, "obsolete movement and stop never reach camera")


def takeover_motion(app, hardware, admin, bridge):
    lease = app.start(app.connect())
    command_ok(app.command(lease, {"pan": "left", "pan.speed": "100"}))
    hardware.move("right").require_ok()
    assert_revoked(app, lease, admin)
    admin.admin("advance", {"seconds": 2})
    equal(admin.admin("state")["info"]["c.1.pan"], "200", "physical joystick owns camera")
    hardware.move().require_ok()
    equal(app.status()["authorized"], False, "joystick release never restarts tracking")
    admin.admin("advance", {"seconds": 30})
    equal(app.status()["authorized"], False, "elapsed time never restarts tracking")
    fresh = app.start(app.current(lease))
    command_ok(app.command(fresh, {"pan": "left", "pan.speed": "100"}))
    admin.admin("advance", {"seconds": 1})
    equal(admin.admin("state")["info"]["c.1.pan"], "100", "new explicit start permits tracking writes")


def held_controls(app, hardware, admin, bridge):
    lease = app.start(app.connect())
    hardware.move("right", "up", 10000).require_ok()
    hardware.command("control.cgi", {"pan": "stop"}).require_ok()
    rejection(app.request("start", app.current(lease)))
    equal(set(app.status()["heldAxes"]), {"tilt"}, "independent axis remains held")
    admin.admin("advance", {"seconds": 20})
    equal(admin.admin("state")["info"]["c.1.tilt.status"], "0", "camera reached tilt limit")
    rejection(app.request("start", app.current(lease)))
    hardware.command("control.cgi", {"tilt": "stop"}).require_ok()
    hardware.zoom("tele", 0).require_ok()
    rejection(app.request("start", app.current(lease)))
    hardware.connection.close()
    rejection(app.request("start", app.current(lease)))
    hardware.zoom("stop").require_ok()
    app.start(app.current(lease))


def takeover_stops_old_app_motion(action):
    def check(app, hardware, admin, bridge):
        lease = app.start(app.connect())
        command_ok(app.command(lease, {"pan": "left", "pan.speed": "100", "tilt": "up",
                                       "tilt.speed": "100", "zoom": "tele", "zoom.speed": "10"}))
        equal(set(admin.admin("state")["commanded_axes"]), {"pan", "tilt", "zoom"}, "app motion is active")
        action(hardware).require_ok()
        assert_revoked(app, lease, admin)
        state = admin.admin("state")
        equal(state["commanded_axes"], [], "focus/store takeover stops previous app-owned axes")
        pose = {axis: state["info"]["c.1." + axis] for axis in ("pan", "tilt", "zoom")}
        admin.admin("advance", {"seconds": 2})
        after = admin.admin("state")
        equal({axis: after["info"]["c.1." + axis] for axis in pose}, pose, "revoked app motion remains stopped")
    return check


def physical_axes_not_stopped_by_subsequent_manual_actions(app, hardware, admin, bridge):
    lease = app.start(app.connect())
    command_ok(app.command(lease, {"tilt": "down", "tilt.speed": "100"}))
    hardware.move("right").require_ok()
    hardware.zoom("tele").require_ok()
    hardware.focus("far").require_ok()
    equal(set(admin.admin("state")["commanded_axes"]), {"pan", "zoom"}, "new manual actions preserve existing hardware axes")
    admin.admin("advance", {"seconds": 1})
    state = admin.admin("state")
    equal(state["info"]["c.1.pan"], "100", "hardware pan still active")
    equal(state["info"]["c.1.zoom"], "3900", "hardware zoom still active")
    equal(state["info"]["c.1.focus.action"], "far", "physical focus was not overwritten by stale stop")
    assert_revoked(app, lease, admin)


def held_focus(app, hardware, admin, bridge):
    lease = app.start(app.connect())
    hardware.focus("near").require_ok()
    rejection(app.request("start", app.current(lease)))
    hardware.focus("stop").require_ok()
    app.start(app.current(lease))


def readonly_traffic(app, hardware, admin, bridge):
    lease = app.start(app.connect())
    generation = app.status()["generation"]
    hardware.connect().require_ok()
    hardware.info("c.1.focus,c.1.pan").require_ok()
    hardware.claim().require_ok()
    equal(app.status()["authorized"], True, "info and session traffic do not take over")
    equal(app.status()["generation"], generation, "info and claim do not revoke generation")
    command_ok(app.command(lease, {"pan": "right", "pan.speed": "100"}))
    hardware.release().require_ok()


def physical_trigger(setup, action, authorize=True):
    def check(app, hardware, admin, bridge):
        setup(hardware, admin)
        lease = app.connect()
        if authorize:
            lease = app.start(app.current(lease))
        else:
            lease = app.current(lease)
        action(hardware).require_ok()
        assert_revoked(app, lease, admin)
    return check


def no_setup(hardware, admin):
    pass


def store_trace(hardware, admin):
    hardware.trace_record("start", 1, "Bridge fixture").require_ok()
    hardware.move("right").require_ok()
    admin.admin("advance", {"seconds": 2})
    hardware.move().require_ok()
    hardware.trace_record("stop").require_ok()


def prepare_trace(hardware, admin):
    store_trace(hardware, admin)
    hardware.trace_play("prepare", 1).require_ok()
    hardware.info().require_ok()


def playing_trace(hardware, admin):
    prepare_trace(hardware, admin)
    hardware.trace_play("start", 1).require_ok()


def app_disconnect(app, hardware, admin, bridge):
    lease = app.start(app.connect())
    command_ok(app.command(lease, {"pan": "left", "pan.speed": "100"}))
    app.request("disconnect", lease).json()
    equal(app.status()["authorized"], False, "disconnected app loses authorization")
    hardware.move("right").require_ok()
    admin.admin("advance", {"seconds": 1})
    equal(admin.admin("state")["info"]["c.1.pan"], "100", "physical control survives app disconnect")
    if bridge.process.poll() is not None:
        raise AssertionError("helper exited with its app client")
    renewed = app.connect()
    equal(app.status()["authorized"], False, "new app connection starts unauthorized")
    rejection(app.command(renewed, {"pan": "left"}))
    rejection(app.command(lease, {"pan": "stop"}))


def authentication(app, hardware, admin, bridge):
    rejection(app.request("status", token="wrong-token"), 401)
    rejection(app.request("connect", {}, version=99), 426)
    lease = app.start(app.connect())
    command_ok(app.command(lease, {"pan": "right", "pan.speed": "100"}))


def revoke_during_first_move(action):
    def scenario(app, hardware, admin, bridge):
        lease = app.start(app.connect())
        admin.admin("fault", {"mode": "delay_after", "seconds": 0.4, "endpoint": "control.cgi"})
        results = []
        thread = threading.Thread(target=lambda: results.append(app.command(lease, {"pan": "left"})))
        thread.start()
        try:
            wait_camera_event(admin, lambda e: e["parameters"].get("pan") == "left")
            equal(app.request(action, lease).status, 200, "stop/disconnect waits for the moving axis")
        finally:
            thread.join(timeout=3)
        equal(len(results), 1, "initial command completed")
        equal(admin.admin("state")["commanded_axes"], [], "revoked first app pan must stop")
    return scenario


def ambiguous_app_motion(app, hardware, admin, bridge):
    lease = app.start(app.connect())
    admin.admin("fault", {"mode": "delay_after", "seconds": 0.5, "endpoint": "control.cgi"})
    if app.command(lease, {"pan": "left"}).status < 400:
        raise AssertionError("Ambiguous camera acknowledgement must report failure")
    equal(admin.admin("state")["commanded_axes"], [], "stop possible app-owned motion even without RC input")
    equal(len([e for e in camera_writes(admin) if e["parameters"].get("pan") == "left"]), 1, "movement never replays")
    hardware.focus("one_shot").require_ok()
    equal(app.status()["authorized"], False, "focus takeover stays disarmed")


def camera_restart_session_recovery(app, hardware, admin, bridge):
    old = app.start(app.connect())
    command_ok(app.command(old, {"pan": "left"}))
    app.request("stop", old).json()
    admin.admin("reset", {})
    fresh = app.start(app.current(old))
    command_ok(app.command(fresh, {"pan": "right"}))
    app.request("stop", fresh).json()
    equal(admin.admin("state")["commanded_axes"], [], "recovered camera accepted move and stop")


def takeover_during_tracking_start(app, hardware, admin, bridge):
    lease = app.connect()
    admin.admin("fault", {"mode": "delay_after", "seconds": 0.4, "endpoint": "info.cgi"})
    result = []
    worker = threading.Thread(target=lambda: result.append(app.request("start", lease)))
    worker.start()
    try:
        wait_camera_event(admin, lambda event: event.get("fault") == "delay_after")
        hardware.focus("far").require_ok()
    finally:
        worker.join(timeout=3)
    equal(len(result), 1, "start completed after the delayed inspection")
    rejection(result[0])
    equal(app.status()["authorized"], False, "physical takeover supersedes an in-flight tracking start")
    equal(admin.admin("state")["info"]["c.1.focus.action"], "far", "physical focus keeps control")


def takeover_during_manual_cleanup(app, hardware, admin, bridge):
    lease = app.start(app.connect())
    command_ok(app.command(lease, {"pan": "left"}))
    admin.admin("fault", {"mode": "delay_after", "seconds": 0.4, "endpoint": "control.cgi"})
    result = []
    worker = threading.Thread(target=lambda: result.append(app.command(lease, {"pan": "1234"}, purpose="manualMove")))
    worker.start()
    try:
        wait_camera_event(admin, lambda e: e["parameters"].get("pan") == "stop")
        hardware.focus("far").require_ok()
    finally:
        worker.join(timeout=3)
    equal(len(result), 1, "manual move caller completed")
    rejection(result[0])
    equal(any(e["parameters"].get("pan") == "1234" for e in camera_writes(admin)), False,
          "physical takeover during cleanup discards the earlier software position move")


def camera_failure(app, hardware, admin, bridge):
    lease = app.start(app.connect())
    admin.admin("fault", {"mode": "disconnect", "endpoint": "control.cgi"})
    reply = app.command(lease, {"pan": "left", "pan.speed": "100"})
    if reply.status < 400:
        raise AssertionError("disconnected upstream must not be reported as accepted movement")
    equal(app.status()["authorized"], False, "camera connection failure revokes tracking")
    left_requests = [event for event in camera_writes(admin) if event["parameters"].get("pan") == "left"]
    equal(len(left_requests), 1, "failed camera command is not replayed")
    hardware.move("right").require_ok()
    equal(app.status()["authorized"], False, "route recovery does not restore tracking")
    rejection(app.command(lease, {"pan": "left"}))


def lease_expiry(app, hardware, admin, bridge):
    lease = app.start(app.connect())
    command_ok(app.command(lease, {"pan": "left", "pan.speed": "100"}))
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline and app.status()["authorized"]:
        time.sleep(0.05)
    equal(app.status()["authorized"], False, "missing app heartbeat expires authority")
    hardware.move("right").require_ok()
    rejection(app.command(lease, {"pan": "stop"}))
    admin.admin("advance", {"seconds": 1})
    equal(admin.admin("state")["info"]["c.1.pan"], "100", "physical motion survives app heartbeat loss")


def diagnostics(app, hardware, admin, bridge):
    hardware.connect().require_ok()
    token = hardware.session
    hardware.focus("one_shot").require_ok()
    hardware.release().require_ok()
    deadline = time.monotonic() + 2
    content = ""
    while time.monotonic() < deadline:
        if bridge.diagnostics_file.exists():
            content = bridge.diagnostics_file.read_text()
        if content.strip():
            break
        time.sleep(0.02)
    if not content.strip():
        raise AssertionError("initial diagnostics default must produce an event timeline")
    if bridge.token in content or token in content:
        raise AssertionError("diagnostics exposed a bearer token or camera session token")
    for line in content.splitlines():
        json.loads(line)
    equal(app.status()["diagnosticsEnabled"], True, "initial diagnostics enabled")


def diagnostics_toggle_during_hardware_hold(app, hardware, admin, bridge):
    lease = app.start(app.connect())
    hardware.move("right", speed=100).require_ok()
    baseline = app.status()
    config = json.loads(bridge.config_file.read_text())
    for enabled in (False, True):
        config["diagnosticsEnabled"] = enabled
        staged = bridge.config_file.with_suffix(".new")
        staged.write_text(json.dumps(config))
        staged.replace(bridge.config_file)
        deadline = time.monotonic() + 2
        while True:
            status = app.status()
            if status["diagnosticsEnabled"] == enabled or time.monotonic() >= deadline:
                break
            time.sleep(0.02)
        equal(status["diagnosticsEnabled"], enabled, "helper applied new diagnostic preference")
        equal(status["connection"], lease["connection"], "same real app lease")
        equal(status["generation"], baseline["generation"], "same manual takeover generation")
        equal(status["heldAxes"], ["pan"], "physical pan remains held")
        equal(admin.admin("state")["commanded_axes"], ["pan"], "real helper leaves camera panning")
    hardware.move().require_ok()
    equal(admin.admin("state")["commanded_axes"], [], "release crossed the unchanged route")
    equal(app.status()["authorized"], False, "release after preference change keeps tracking off")


def diagnostics_disabled(app, hardware, admin, bridge):
    hardware.move("right").require_ok()
    equal(app.status()["diagnosticsEnabled"], False, "diagnostics opt-out honored")
    if bridge.diagnostics_file.exists() and bridge.diagnostics_file.read_text().strip():
        raise AssertionError("diagnostics opt-out still recorded detailed events")


def failed_diagnostics_storage(app, hardware, admin, bridge):
    hardware.focus("one_shot").require_ok()
    hardware.move("right").require_ok()
    admin.admin("advance", {"seconds": 1})
    equal(admin.admin("state")["info"]["c.1.pan"], "100", "physical motion survives unavailable log file")
    status = app.status()
    if status["droppedDiagnosticEvents"] < 1:
        raise AssertionError("failed diagnostic writes must be observable as reduced coverage")


def in_flight_takeover(app, hardware, admin, bridge):
    lease = app.start(app.connect())
    admin.admin("fault", {"mode": "delay_after", "seconds": 0.5, "endpoint": "control.cgi"})
    result = []
    failure = []

    def software_write():
        try:
            result.append(app.command(lease, {"pan": "left", "pan.speed": "100"}))
        except Exception as error:
            failure.append(error)

    software = threading.Thread(target=software_write, daemon=True)
    software.start()
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if any(event["parameters"].get("pan") == "left" for event in camera_writes(admin)):
            break
        time.sleep(0.005)
    else:
        raise AssertionError("in-flight app write never reached camera")

    def manual_write():
        try:
            hardware.focus("far").require_ok()
        except Exception as error:
            failure.append(error)

    manual = threading.Thread(target=manual_write, daemon=True)
    manual.start()
    try:
        deadline = time.monotonic() + 0.35
        while time.monotonic() < deadline and app.status()["authorized"]:
            time.sleep(0.005)
        equal(app.status()["authorized"], False, "takeover revokes while old app write is in flight")
        rejection(app.command(lease, {"pan": "stop"}))
    finally:
        software.join(timeout=3)
        manual.join(timeout=3)
    if software.is_alive() or manual.is_alive():
        raise AssertionError("in-flight takeover did not resolve within a bounded interval")
    if failure:
        raise failure[0]
    equal(admin.admin("state")["commanded_axes"], [], "old in-flight motion cannot survive focus takeover")
    equal(admin.admin("state")["info"]["c.1.focus.action"], "far", "late app stop cannot overwrite focus")
    assert_revoked(app, lease, admin)


def slow_info_does_not_block_movement(app, hardware, admin, bridge):
    admin.admin("fault", {"mode": "delay", "seconds": 1, "endpoint": "info.cgi"})
    result = []

    def read():
        try:
            with Controller(bridge.controller_url) as reader:
                result.append(reader.info().require_ok())
        except Exception as error:
            result.append(error)

    thread = threading.Thread(target=read, daemon=True)
    thread.start()
    time.sleep(0.08)
    try:
        hardware.move("right").require_ok()
        if not thread.is_alive():
            raise AssertionError("movement waited for the slow information request")
        equal(admin.admin("state")["commanded_axes"], ["pan"], "movement reached camera during slow read")
    finally:
        thread.join(timeout=3)
    if not result or isinstance(result[0], Exception):
        raise AssertionError("slow information response did not complete successfully")


def malformed_requests_do_not_crash_helper(app, hardware, admin, bridge):
    host, port = loopback_url(bridge.controller_url)
    requests = (
        (b"POST /-wvhttp-01-/control.cgi HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 3\r\n\r\n", False),
        (b"POST /-wvhttp-01-/control.cgi HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n0\r\n\r\n", False),
        (b"POST /-wvhttp-01-/control.cgi HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2000000\r\n\r\n", False),
        (b"GET /-wvhttp-01-/control.cgi?pan=right&&pan.speed=100 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", True),
        (b"GET /%ZZ HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", False),
    )
    for data, may_succeed in requests:
        with socket.create_connection((host, port), timeout=2) as connection:
            connection.sendall(data)
            try:
                response = connection.recv(4096)
            except ConnectionResetError:
                response = b""
            if response and not may_succeed:
                status = int(response.split(b" ", 2)[1])
                if status < 400:
                    raise AssertionError("ambiguous framing or malformed URI was accepted")
        hardware.move().require_ok()
        hardware.info().require_ok()
    if bridge.process.poll() is not None:
        raise AssertionError("helper crashed on malformed input")


def malformed_camera_response(app, hardware, admin, bridge):
    lease = app.start(app.connect())
    admin.admin("fault", {"mode": "malformed", "endpoint": "control.cgi"})
    if app.command(lease, {"pan": "left", "pan.speed": "100"}).status < 400:
        raise AssertionError("malformed upstream response was reported as success")
    equal(app.status()["authorized"], False, "malformed camera response revokes authorization")
    hardware.move("right").require_ok()
    if bridge.process.poll() is not None:
        raise AssertionError("helper crashed on malformed camera response")


def wait_camera_event(admin, predicate, timeout=2):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if any(predicate(event) for event in admin.admin("events")["events"]):
            return
        time.sleep(0.005)
    raise AssertionError("expected in-flight camera request was not observed")


def pending_physical_action(action, endpoint):
    def check(app, hardware, admin, bridge):
        lease = app.connect()
        admin.admin("fault", {"mode": "delay_after", "seconds": 0.5, "endpoint": endpoint})
        results = []

        def send():
            try:
                results.append(action(hardware).require_ok())
            except Exception as error:
                results.append(error)

        thread = threading.Thread(target=send, daemon=True)
        thread.start()
        try:
            wait_camera_event(admin, lambda event: event["endpoint"] == endpoint)
            rejection(app.request("start", app.current(lease)))
        finally:
            thread.join(timeout=3)
        if not results or isinstance(results[0], Exception):
            raise AssertionError("pending physical action did not finish successfully")
        equal(app.status()["authorized"], False, "physical completion does not automatically start tracking")
    return check


def ambiguous_physical_motion_blocks_restart(app, hardware, admin, bridge):
    lease = app.connect()
    admin.admin("fault", {"mode": "delay_after", "seconds": 0.5, "endpoint": "control.cgi"})
    results = []

    def send():
        try:
            results.append(hardware.move("right"))
        except Exception as error:
            results.append(error)

    thread = threading.Thread(target=send, daemon=True)
    thread.start()
    try:
        wait_camera_event(admin, lambda event: event["parameters"].get("pan") == "right")
        rejection(app.request("start", app.current(lease)))
    finally:
        thread.join(timeout=3)
    if not results or isinstance(results[0], Exception) or results[0].status < 400:
        raise AssertionError("ambiguous physical movement must surface its upstream timeout")
    hardware.info().require_ok()
    rejection(app.request("start", app.current(lease)))
    equal(admin.admin("state")["commanded_axes"], ["pan"], "uncertain physical movement intent remains held")
    hardware.move().require_ok()
    app.start(app.current(lease))


def completed_preset_allows_explicit_restart(app, hardware, admin, bridge):
    hardware.preset_store(1, "Fixture").require_ok()
    lease = app.connect()
    hardware.preset_recall(1).require_ok()
    before = admin.admin("events")["last_sequence"]
    app.start(app.current(lease))
    events = admin.admin("events")["events"]
    if not any(event["endpoint"] == "info.cgi" and event["sequence"] > before for event in events):
        raise AssertionError("explicit restart after preset needs fresh camera completion evidence")
    equal(app.status()["authorized"], True, "completed preset permits explicit restart")


def absolute_app_motion_then_store(app, hardware, admin, bridge):
    lease = app.start(app.connect())
    command_ok(app.command(lease, {"pan": "900", "tilt": "-200", "zoom": "4000"}))
    hardware.preset_store(1).require_ok()
    assert_revoked(app, lease, admin)
    equal(admin.admin("state")["commanded_axes"], [], "no revoked app axes remain active after absolute move and store")


def concurrent_stop_and_disconnect(app, hardware, admin, bridge):
    lease = app.start(app.connect())
    command_ok(app.command(lease, {"pan": "left", "pan.speed": "100"}))
    admin.admin("fault", {"mode": "delay_after", "seconds": 0.5, "endpoint": "control.cgi"})
    results = []

    def stop():
        try:
            results.append(app.request("stop", lease))
        except Exception as error:
            results.append(error)

    thread = threading.Thread(target=stop, daemon=True)
    thread.start()
    try:
        wait_camera_event(admin, lambda event: event["parameters"].get("pan") == "stop")
        reply = app.request("disconnect", app.current(lease))
        if reply.status not in (200, 409):
            raise AssertionError("concurrent disconnect did not complete or reject its obsolete lease")
    finally:
        thread.join(timeout=3)
    if bridge.process.poll() is not None:
        raise AssertionError("helper crashed when disconnect invalidated an awaiting stop")
    if not results or isinstance(results[0], Exception) or results[0].status not in (200, 409):
        raise AssertionError("awaiting stop did not finish safely after concurrent disconnect")
    hardware.move("right").require_ok()
    equal(admin.admin("state")["commanded_axes"], ["pan"], "physical forwarding survives stop/disconnect race")


def exclusive_session_recovery(app, hardware, admin, bridge):
    hardware.connect().require_ok()
    with Controller(bridge.camera_url) as observer:
        observer_session = observer.command("open.cgi").require_ok().fields["s"]
        info = hardware.command("info.cgi", {"s": observer_session})
        equal(info.livescope.split()[0], "501", "camera session credentials cannot be used on the controller listener")
        observer.command("close.cgi", {"s": observer_session}).require_ok()
    lease = app.start(app.connect())
    equal(hardware.info().require_ok().fields["s.control"], "enabled", "status poll cannot replace the controller session")
    command_ok(app.command(lease, {"pan": "left", "pan.speed": "100"}))
    admin.admin("fault", {"mode": "disconnect", "endpoint": "control.cgi"})
    if app.command(lease, {"pan": "left", "pan.speed": "100"}).status < 400:
        raise AssertionError("camera disconnect was not surfaced")
    hardware.move("right").require_ok()
    hardware.move().require_ok()
    fresh = app.start(app.current(lease))
    command_ok(app.command(fresh, {"pan": "left", "pan.speed": "100"}))
    hardware.move("right").require_ok()
    equal(app.status()["authorized"], False, "physical controller still takes over after session recovery")
    equal(admin.admin("state")["commanded_axes"], ["pan"], "recovered helper never steals controller session")


def virtual_controller_lifecycle(app, hardware, admin, bridge):
    wait_camera_event(admin, lambda e: e["endpoint"] == "claim.cgi" and e["livescope"] == "0", timeout=5)
    upstream_claim = next(e for e in admin.admin("events")["events"] if e["endpoint"] == "claim.cgi")
    opened = hardware.command("open.cgi", {"s.priority": "4"}).require_ok()
    hardware.session = opened.fields["s"]
    downstream = hashlib.sha256(hardware.session.encode()).hexdigest()[:16]
    equal(opened.fields["s.origin"].removeprefix("http://").rstrip("/"),
          bridge.controller_url.removeprefix("http://"), "controller origin points back to bridge")
    if upstream_claim["session_fingerprint"] in (None, downstream):
        raise AssertionError("controller and camera must use separate session IDs")
    hardware.claim().require_ok()
    controller_session = hardware.session
    hardware.move("right").require_ok()
    hardware.move().require_ok()
    hardware.command("yield.cgi").require_ok()
    equal(hardware.info().require_ok().fields["s.control"], "disabled", "yield updates the virtual info view")
    equal(hardware.move("left").livescope.split()[0], "301", "yielded controller cannot issue movement")
    hardware.claim().require_ok()
    equal(hardware.info().require_ok().fields["s.control"], "enabled", "claim restores the virtual info view")
    hardware.release().require_ok()
    equal(hardware.command("info.cgi", {"s": controller_session}).livescope.split()[0], "501",
          "closed controller session is invalidated locally")
    hardware.connect().require_ok()
    equal(hardware.session != controller_session, True, "reopen gets a fresh controller credential")
    hardware.zoom("tele").require_ok()
    hardware.zoom("stop").require_ok()
    hardware.release().require_ok()
    events = admin.admin("events")["events"]
    for endpoint in ("close.cgi", "yield.cgi"):
        equal(any(e["endpoint"] == endpoint for e in events), False, "controller lifecycle stays local")
    equal(sum(e["endpoint"] == "open.cgi" for e in events), 1, "controller reopens reuse one camera session")
    for event in events:
        if event["endpoint"] in ("claim.cgi", "control.cgi"):
            equal(event["session_fingerprint"], upstream_claim["session_fingerprint"], "camera-side credential is stable")
    equal(admin.admin("state")["session_count"], 1, "controller close leaves upstream session open")


def idle_session_maintenance(app, hardware, admin, bridge):
    wait_camera_event(admin, lambda e: e["endpoint"] == "claim.cgi" and e["livescope"] == "0", timeout=5)
    initial = admin.admin("events")
    first_claim = next(e for e in initial["events"] if e["endpoint"] == "claim.cgi")
    wait_camera_event(admin, lambda e: e["endpoint"] == "claim.cgi" and e["livescope"] == "0"
                      and e["sequence"] > initial["last_sequence"]
                      and e["session_fingerprint"] == first_claim["session_fingerprint"], timeout=10)
    admin.admin("expire-sessions", {})
    wait_camera_event(admin, lambda e: e["endpoint"] == "claim.cgi" and e["livescope"] == "0"
                      and e["session_fingerprint"] != first_claim["session_fingerprint"], timeout=12)
    equal(admin.admin("state")["session_count"], 1, "idle helper reclaims one session after expiration")
    equal(app.status()["authorized"], False, "camera maintenance does not authorize tracking")


def release_during_session_expiry(app, hardware, admin, bridge):
    hardware.connect().require_ok()
    controller_session = hardware.session
    lease = app.start(app.connect())
    command_ok(app.command(lease, {"pan": "left"}))
    hardware.move("right").require_ok()
    assert_revoked(app, lease, admin)
    before = admin.admin("events")["last_sequence"]
    admin.admin("expire-sessions", {})
    equal(admin.admin("state")["commanded_axes"], ["pan"], "loss of session did not stop physical pan")
    hardware.move()  # May report the original rejection. The recovery stop must still be acknowledged.
    wait_camera_event(admin, lambda e: e["sequence"] > before and e["endpoint"] == "control.cgi" and e["livescope"] == "0"
                      and e["parameters"].get("pan") == e["parameters"].get("tilt")
                      == e["parameters"].get("zoom") == e["parameters"].get("focus.action") == "stop",
                      timeout=8)
    equal(admin.admin("state")["commanded_axes"], [], "camera stopped before admitting any new movement")
    equal(app.status()["authorized"], False, "recovery leaves tracking off")
    hardware.info().require_ok()
    hardware.move("left", speed=37).require_ok()
    hardware.move().require_ok()
    equal(hardware.session, controller_session, "same controller session accepted fresh movement")
    rejection(app.command(lease, {"tilt": "up"}))
    command_ok(app.command(app.start(app.current(lease)), {"pan": "left", "pan.speed": "234"}))
    writes = camera_writes(admin)
    equal(sum(e["parameters"].get("pan") == "right" for e in writes), 1, "expired motion was not replayed")
    equal(writes[-1]["parameters"].get("pan.speed"), "234", "only fresh tracking move followed recovery")


def queued_movement_dropped_on_session_loss(app, hardware, admin, bridge):
    hardware.connect().require_ok()
    lease = app.start(app.connect())
    hardware.move("right", speed=100).require_ok()
    admin.admin("expire-sessions", {})
    admin.admin("fault", {"mode": "delay", "seconds": 0.8, "endpoint": "control.cgi"})

    def invoke(peer, pan, speed):
        # All peers represent overlapping HTTP requests from the same RC-IP100 session.
        peer.session = hardware.session
        peer.move(pan, speed=speed)

    def wait_job(decision, speed):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            for line in bridge.diagnostics_file.read_bytes().splitlines():
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if event["decision"] == decision and event["parameters"].get("pan.speed") == str(speed):
                    return
            time.sleep(0.005)
        raise AssertionError("expected physical job was not visible in helper diagnostics")

    with Controller(bridge.controller_url) as first, Controller(bridge.controller_url) as queued:
        in_flight = threading.Thread(target=invoke, args=(first, "left", 571))
        stale = threading.Thread(target=invoke, args=(queued, "right", 572))
        in_flight.start()
        try:
            wait_job("dispatched", 571)
            stale.start()
            wait_job("enqueued", 572)
            hardware.move()
        finally:
            in_flight.join(timeout=3)
            if stale.ident is not None:
                stale.join(timeout=3)
    wait_camera_event(admin, lambda e: e["parameters"].get("focus.action") == "stop", timeout=8)
    writes = camera_writes(admin)
    equal([e["livescope"] for e in writes if e["parameters"].get("pan.speed") == "571"], ["501"],
          "only the original attempted movement reached the expired camera session")
    equal(any(e["parameters"].get("pan.speed") == "572" for e in writes), False,
          "queued movement never reaches the replacement session")
    equal(admin.admin("state")["commanded_axes"], [], "outage release resolves through a confirmed stop")
    command_ok(app.command(app.start(app.current(lease)), {"pan": "stop"}))


def cleanup_failure_still_forwards_physical_action(app, hardware, admin, bridge):
    lease = app.start(app.connect())
    command_ok(app.command(lease, {"pan": "left", "pan.speed": "100"}))
    admin.admin("fault", {"mode": "livescope", "endpoint": "control.cgi", "code": 408})
    hardware.focus("far").require_ok()
    equal(admin.admin("state")["info"]["c.1.focus.action"], "far", "physical action forwarded despite old-motion cleanup error")
    equal(app.status()["authorized"], False, "cleanup failure cannot restore tracking")
    rejection(app.request("start", app.current(lease)))


def streaming_info_forwards_before_completion(app, hardware, admin, bridge):
    admin.admin("fault", {"mode": "stream", "seconds": 1, "endpoint": "info.cgi"})
    first = threading.Event()
    finished = threading.Event()
    result = []

    def read():
        host, port = loopback_url(bridge.controller_url)
        connection = http.client.HTTPConnection(host, port, timeout=4)
        try:
            connection.request("GET", "/-wvhttp-01-/info.cgi")
            response = connection.getresponse()
            line = response.readline()
            result.append((response.status, line))
            first.set()
            result.append(response.read())
        except Exception as error:
            result.append(error)
        finally:
            finished.set()
            connection.close()

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    try:
        if not first.wait(timeout=0.6) or finished.is_set():
            raise AssertionError("controller did not receive initial streaming information before completion")
        hardware.move("right").require_ok()
        hardware.move().require_ok()
        if finished.is_set():
            raise AssertionError("joystick commands waited for the information stream to finish")
        equal(admin.admin("state")["commanded_axes"], [], "joystick stop forwarded while stream remained open")
    finally:
        reader.join(timeout=4)
    if reader.is_alive() or len(result) != 2 or isinstance(result[-1], Exception):
        raise AssertionError("stream did not complete cleanly after concurrent movement")
    equal(result[0][0], 200, "stream HTTP status")
    if b"rig.stream.frame:=2" not in result[1]:
        raise AssertionError("stream lost its final synthetic transport frame")


def software_controls_preserve_tracking(app, hardware, admin, bridge):
    lease = app.start(app.connect())
    command_ok(app.command(lease, {"pan": "left", "pan.speed": "100"}))
    operations = ({"zoom": "tele", "zoom.speed": "10"}, {"zoom": "stop"},
                  {"focus": "manual"}, {"focus.action": "one_shot"},
                  {"focus.action": "far"}, {"focus.action": "stop"})
    for parameters in operations:
        command_ok(app.command(lease, parameters, purpose="manual"))
        status = app.status()
        equal(status["authorized"], True, "ordinary software zoom/focus preserves tracking authorization")
        equal(status["generation"], lease["generation"], "ordinary software controls preserve the current lease")
    command_ok(app.command(lease, {"pan": "right", "pan.speed": "100"}))


def software_exposure_forwarding_preserves_helper_authorization(app, hardware, admin, bridge):
    lease = app.start(app.connect())
    # Exposure physics/values are deliberately outside the camera profile. Its
    # unsupported-parameter reply still proves transport without changing policy.
    reply = app.command(lease, {"exp": "manual", "me.gain.mode": "manual", "me.gain": "6"}, purpose="manual").json()
    equal(reply["status"], 200, "exposure request reaches camera endpoint")
    equal(reply["headers"].get("livescope-status"), "401", "camera profile explicitly rejects unmodeled exposure fields")
    equal(app.status()["authorized"], True, "software exposure request does not revoke helper authorization")
    command_ok(app.command(lease, {"pan": "right", "pan.speed": "100"}))


def software_manual_move(action, setup=no_setup):
    def check(app, hardware, admin, bridge):
        setup(hardware, admin)
        lease = app.start(app.connect())
        command_ok(app.command(lease, {"pan": "left", "pan.speed": "100", "tilt": "up",
                                       "tilt.speed": "100", "zoom": "tele", "zoom.speed": "10"}))
        command_ok(app.command(lease, action, purpose="manualMove"))
        equal(app.status()["authorized"], False, "explicit software movement stops tracking authorization")
        equal(app.status()["generation"], lease["generation"], "ordered software movement keeps its captured lease")
        equal(admin.admin("state")["commanded_axes"], [], "software home/preset/position replaces prior tracking motion")
        rejection(app.command(lease, {"pan": "left", "pan.speed": "100"}))
        command_ok(app.command(lease, {"pan": "right", "pan.speed": "100"}, purpose="manualMove"))
        command_ok(app.command(lease, {"pan": "stop", "tilt": "stop", "zoom": "stop"}, purpose="manualMove"))
        equal(admin.admin("state")["commanded_axes"], [], "software joystick release succeeds with its original lease")
        hardware.move("right").require_ok()
        rejection(app.command(lease, {"pan": "stop"}, purpose="manualMove"))
        equal(admin.admin("state")["commanded_axes"], ["pan"], "physical takeover still rejects obsolete software release")
    return check


def helper_restart_with_held_joystick(app, hardware, admin, bridge):
    lease = app.start(app.connect())
    hardware.move("right", speed=10000).require_ok()
    admin.admin("advance", {"seconds": 20})
    state = admin.admin("state")
    equal(state["info"]["c.1.pan.status"], "0", "held joystick reached a travel limit")
    equal(state["commanded_axes"], ["pan"], "travel limit is not joystick release")
    bridge.process.kill()
    bridge.process.wait(timeout=3)
    with BridgeProcess(bridge.binary, bridge.camera_url, bridge.directory) as restarted:
        equal(restarted.token, bridge.token, "restart reuses configured app credentials")
        recovered_app = AppClient(restarted.app_url, restarted.token)
        recovered_app.observations = app.observations
        recovered_lease = recovered_app.connect()
        equal(recovered_app.status()["authorized"], False, "helper restart keeps tracking off")
        rejection(recovered_app.request("start", recovered_app.current(recovered_lease)))
        with Controller(restarted.controller_url) as recovered_hardware:
            recovered_hardware.move().require_ok()
            recovered_hardware.zoom("stop").require_ok()
            recovered_hardware.info().require_ok()
            equal(recovered_app.status()["heldAxes"], [], "confirmed autofocus clears startup focus without a focus stop")
            command_ok(recovered_app.command(recovered_app.current(recovered_lease), {"pan": "stop"}, purpose="manualMove"))
            recovered_hardware.focus("near").require_ok()
            recovered_hardware.info().require_ok()
            rejection(recovered_app.request("start", recovered_app.current(recovered_lease)))
            recovered_hardware.focus("stop").require_ok()
            recovered_app.start(recovered_app.current(recovered_lease))
        equal(recovered_app.status()["authorized"], True, "explicit hardware stops clear restart recovery fence")


OWNERSHIP_SCENARIOS = (
    ("manual_takeover_latched_explicit_restart", takeover_motion, {}),
    ("independent_axes_limits_speed_zero_and_connection_close", held_controls, {}),
    ("focus_takeover_stops_previous_app_motion", takeover_stops_old_app_motion(lambda h: h.focus("far")), {}),
    ("preset_store_takeover_stops_previous_app_motion", takeover_stops_old_app_motion(lambda h: h.preset_store(1)), {}),
    ("subsequent_manual_actions_preserve_hardware_axes", physical_axes_not_stopped_by_subsequent_manual_actions, {}),
    ("held_focus_blocks_explicit_restart", held_focus, {}),
    ("readonly_and_claim_traffic_do_not_take_over", readonly_traffic, {}),
    ("zoom_takeover", physical_trigger(no_setup, lambda h: h.zoom("tele")), {}),
    ("focus_mode_takeover", physical_trigger(no_setup, lambda h: h.command("control.cgi", {"focus": "manual"})), {}),
    ("focus_one_shot_takeover", physical_trigger(no_setup, lambda h: h.focus("one_shot")), {}),
    ("focus_motion_takeover", physical_trigger(no_setup, lambda h: h.focus("far")), {}),
    ("preset_store_takeover", physical_trigger(no_setup, lambda h: h.preset_store(1, "Fixture α")), {}),
    ("preset_recall_takeover", physical_trigger(lambda h, a: h.preset_store(1).require_ok(), lambda h: h.preset_recall(1)), {}),
    ("trace_record_start_takeover", physical_trigger(no_setup, lambda h: h.trace_record("start", 1)), {}),
    ("trace_record_stop_takeover", physical_trigger(lambda h, a: h.trace_record("start", 1).require_ok(), lambda h: h.trace_record("stop"), False), {}),
    ("trace_record_cancel_takeover", physical_trigger(lambda h, a: h.trace_record("start", 1).require_ok(), lambda h: h.trace_record("cancel"), False), {}),
    ("trace_prepare_takeover", physical_trigger(store_trace, lambda h: h.trace_play("prepare", 1)), {}),
    ("trace_play_start_takeover", physical_trigger(prepare_trace, lambda h: h.trace_play("start", 1)), {}),
    ("trace_play_stop_takeover", physical_trigger(playing_trace, lambda h: h.trace_play("stop"), False), {}),
    ("authenticated_versioned_app_interface", authentication, {}),
    ("app_disconnect_keeps_physical_forwarding", app_disconnect, {}),
    ("stop_during_first_tracking_move", revoke_during_first_move("stop"), {}),
    ("disconnect_during_first_tracking_move", revoke_during_first_move("disconnect"), {}),
    ("uncertain_app_motion_stops_without_replay", ambiguous_app_motion, {"extra_args": ("--request-timeout", "0.15")}),
    ("expired_camera_session_recovered_on_explicit_start", camera_restart_session_recovery, {"camera_ownership": "exclusive"}),
    ("physical_takeover_during_tracking_start", takeover_during_tracking_start, {}),
    ("physical_takeover_during_manual_move_cleanup", takeover_during_manual_cleanup, {}),
    ("absolute_focus_takeover", physical_trigger(no_setup, lambda h: h.command("control.cgi", {"c.1.focus.value": "500"})), {}),
    ("camera_failure_disarms_without_replay", camera_failure, {}),
    ("malformed_camera_response_disarms_and_recovers", malformed_camera_response, {}),
    ("bounded_in_flight_write_and_manual_takeover", in_flight_takeover, {}),
    ("slow_information_does_not_block_movement", slow_info_does_not_block_movement, {}),
    ("malformed_requests_do_not_crash_helper", malformed_requests_do_not_crash_helper, {}),
    ("pending_focus_blocks_explicit_restart", pending_physical_action(lambda h: h.command("control.cgi", {"focus": "manual"}), "control.cgi"), {}),
    ("pending_preset_store_blocks_explicit_restart", pending_physical_action(lambda h: h.preset_store(1), "preset/set"), {}),
    ("ambiguous_physical_motion_stays_held_after_recovery", ambiguous_physical_motion_blocks_restart, {"extra_args": ("--request-timeout", "0.15")}),
    ("completed_preset_allows_explicit_restart_with_fresh_evidence", completed_preset_allows_explicit_restart, {}),
    ("absolute_app_motion_then_store_revokes", absolute_app_motion_then_store, {}),
    ("concurrent_stop_disconnect_keeps_helper_alive", concurrent_stop_and_disconnect, {}),
    ("queued_physical_movement_is_discarded_on_session_loss", queued_movement_dropped_on_session_loss, {"camera_ownership": "exclusive"}),
    ("idle_upstream_session_renewal", idle_session_maintenance, {"camera_ownership": "exclusive"}),
    ("virtual_controller_lifecycle_is_independent", virtual_controller_lifecycle, {"camera_ownership": "exclusive"}),
    ("release_during_session_expiry_stops_before_restart", release_during_session_expiry, {"camera_ownership": "exclusive"}),
    ("exclusive_controller_session_survives_route_recovery", exclusive_session_recovery, {"camera_ownership": "exclusive"}),
    ("cleanup_failure_still_forwards_physical_action", cleanup_failure_still_forwards_physical_action, {}),
    ("streaming_info_reaches_controller_before_completion", streaming_info_forwards_before_completion, {}),
    ("software_zoom_and_focus_preserve_tracking", software_controls_preserve_tracking, {}),
    ("software_exposure_request_preserves_helper_authorization", software_exposure_forwarding_preserves_helper_authorization, {}),
    ("software_position_move_disables_tracking_atomically", software_manual_move({"pan": "900", "tilt": "-200", "zoom": "4000"}), {}),
    ("software_home_disables_tracking_atomically", software_manual_move({"pan": "0", "tilt": "0"}), {}),
    ("software_preset_disables_tracking_atomically", software_manual_move({"p": "1"}, lambda h, a: h.preset_store(1).require_ok()), {}),
    ("helper_restart_preserves_unknown_held_joystick_at_limit", helper_restart_with_held_joystick, {}),
    ("app_heartbeat_loss_keeps_physical_forwarding", lease_expiry, {"extra_args": ("--lease-timeout", "1")}),
    ("initial_diagnostics_and_secret_redaction", diagnostics, {}),
    ("diagnostics_opt_out", diagnostics_disabled, {"diagnostics": False}),
    ("live_diagnostics_preserves_physical_hold_and_release", diagnostics_toggle_during_hardware_hold, {"config_file": True}),
    ("failed_diagnostics_storage_preserves_physical_control", failed_diagnostics_storage, {"diagnostics_directory": True}),
)


def verify_bridge(binary, *, ownership="both", transport_only=False):
    """Run the supported transport profile through the actual helper process."""
    started = time.monotonic()
    checks = []
    profiles = ("documented", "exclusive") if ownership == "both" else (ownership,)
    for profile in profiles:
        with tempfile.TemporaryDirectory(prefix="camera-bridge-check-") as directory:
            with CameraSimulator(clock="manual", ownership=profile) as camera:
                with BridgeProcess(binary, camera.url, directory) as bridge:
                    report = verify(bridge.controller_url, camera.url)
                    for check in report["checks"]:
                        checks.append({**check, "name": profile + "/transport/" + check["name"]})
    if not transport_only:
        for name, scenario, options in OWNERSHIP_SCENARIOS:
            at = time.monotonic()
            evidence = []
            app_evidence = []
            options = dict(options)
            camera_ownership = options.pop("camera_ownership", "documented")
            try:
                with tempfile.TemporaryDirectory(prefix="camera-bridge-policy-") as directory:
                    with CameraSimulator(clock="manual", ownership=camera_ownership) as camera, Controller(camera.url) as admin:
                        with BridgeProcess(binary, camera.url, directory, **options) as bridge:
                            with Controller(bridge.controller_url) as hardware:
                                app = AppClient(bridge.app_url, bridge.token)
                                try:
                                    scenario(app, hardware, admin, bridge)
                                finally:
                                    evidence = admin.admin("events")["events"]
                                    app_evidence = sorted(app.observations, key=lambda event: event["time_monotonic"])
                checks.append({"name": "ownership/" + name, "passed": True,
                               "ownership_profile": camera_ownership, "app_events": app_evidence,
                               "duration_ms": round((time.monotonic() - at) * 1000, 3), "camera_events": evidence})
            except Exception as error:
                checks.append({"name": "ownership/" + name, "passed": False,
                               "ownership_profile": camera_ownership, "app_events": app_evidence,
                               "error": f"{type(error).__name__}: {error}", "camera_events": evidence,
                               "duration_ms": round((time.monotonic() - at) * 1000, 3)})
    return {"schema_version": 1, "generated_at": datetime.now(timezone.utc).isoformat(),
            "mode": "actual_bridge_process", "bridge_binary": str(Path(binary).resolve()),
            "bridge_binary_sha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
            "transport_profiles_verified": list(profiles),
            "helper_ownership_profiles_exercised": [] if transport_only else ["documented", "exclusive"],
            "passed": bool(checks) and all(check["passed"] for check in checks),
            "duration_ms": round((time.monotonic() - started) * 1000, 3), "checks": checks,
            "tracking_handoff_verified": False,
            "helper_ownership_verified": not transport_only and all(check["passed"] for check in checks
                                                                   if check["name"].startswith("ownership/")),
            "not_covered": ["actual Churchfront tracking adapter and app lifecycle",
                            "actual RC-IP100 firmware, camera authentication and native tracking controls",
                            "camera image processing, lens and mechanical behavior"]}
