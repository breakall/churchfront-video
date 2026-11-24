"""Scriptable controller that uses the network, never the simulator's internals."""

from dataclasses import dataclass
import http.client
import ipaddress
import json
from urllib.parse import urlencode, urlsplit


def loopback_url(url):
    parsed = urlsplit(url)
    if parsed.scheme != "http" or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("use an http:// loopback URL without credentials or query")
    host = parsed.hostname
    if host == "localhost":
        host = "127.0.0.1"
    try:
        valid = ipaddress.ip_address(host).is_loopback
    except ValueError:
        valid = False
    if not valid or parsed.path not in ("", "/"):
        raise ValueError("test rig targets must be loopback addresses")
    return host, parsed.port or 80


@dataclass
class Reply:
    status: int
    headers: dict
    body: bytes

    @property
    def livescope(self):
        return self.headers.get("livescope-status", "")

    @property
    def fields(self):
        result = {}
        for line in self.body.decode("utf-8", errors="replace").splitlines():
            for separator in (":=", "=="):
                if separator in line:
                    key, value = line.split(separator, 1)
                    result[key] = value
                    break
        return result

    def require_ok(self):
        if self.status != 200 or self.livescope != "0":
            raise RuntimeError(f"camera request failed: HTTP {self.status}, Livescope {self.livescope}")
        return self

    def json(self):
        if self.status != 200:
            raise RuntimeError(f"rig request failed: HTTP {self.status}")
        return json.loads(self.body)


class Controller:
    def __init__(self, target, *, timeout=2, actor="controller"):
        host, port = loopback_url(target)
        if actor not in ("controller", "software"):
            raise ValueError("actor must be controller or software")
        self.connection = http.client.HTTPConnection(host, port, timeout=timeout)
        self.actor = actor
        self.session = None

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.connection.close()

    def request(self, path, *, method="GET", body=None, content_type=None):
        headers = {"User-Agent": f"CameraTestRig/{self.actor}"}
        if content_type:
            headers["Content-Type"] = content_type
        try:
            self.connection.request(method, path, body=body, headers=headers)
            response = self.connection.getresponse()
            payload = response.read(1048577)
            if len(payload) > 1048576:
                raise ValueError("response exceeded test rig limit")
            return Reply(response.status, {k.lower(): v for k, v in response.getheaders()}, payload)
        except Exception:
            self.connection.close()
            raise

    def command(self, endpoint, parameters=None, *, method="GET"):
        if endpoint not in ("info.cgi", "control.cgi", "open.cgi", "claim.cgi", "yield.cgi", "close.cgi",
                            "preset/set", "trace/set", "trace/control"):
            raise ValueError("unsupported rig command endpoint")
        parameters = dict(parameters or {})
        if self.session and endpoint != "open.cgi":
            parameters.setdefault("s", self.session)
        encoded = urlencode(parameters).encode("ascii")
        path = "/-wvhttp-01-/" + endpoint
        if method == "POST":
            return self.request(path, method="POST", body=encoded,
                                content_type="application/x-www-form-urlencoded")
        if method != "GET":
            raise ValueError("use GET or POST")
        return self.request(path + ("?" + encoded.decode() if encoded else ""))

    def info(self, item=None):
        return self.command("info.cgi", {"item": item} if item else {})

    def connect(self, priority=0):
        reply = self.command("open.cgi", {"s.priority": priority}).require_ok()
        self.session = reply.fields["s"]
        return self.claim()

    def claim(self):
        return self.command("claim.cgi")

    def release(self):
        reply = self.command("close.cgi")
        if reply.livescope == "0":
            self.session = None
        return reply

    def move(self, pan="stop", tilt="stop", speed=100):
        return self.command("control.cgi", {"pan": pan, "tilt": tilt,
                                            "pan.speed": speed, "tilt.speed": speed})

    def zoom(self, direction, speed=10):
        return self.command("control.cgi", {"zoom": direction, "zoom.speed": speed})

    def focus(self, action):
        return self.command("control.cgi", {"focus.action": action})

    def preset_store(self, number, name=""):
        return self.command("preset/set", {"p": number, "name": name, "all": "enabled"}, method="POST")

    def preset_recall(self, number):
        return self.command("control.cgi", {"p": number})

    def trace_record(self, action, number=None, name=""):
        parameters = {"cmd": action}
        if number is not None:
            parameters.update(t=number, name=name)
        return self.command("trace/set", parameters, method="POST")

    def trace_play(self, action, number=None):
        parameters = {"cmd": action}
        if number is not None:
            parameters["t"] = number
        return self.command("trace/control", parameters)

    def admin(self, action, data=None):
        path = "/__rig/" + action
        if data is None:
            return self.request(path).json()
        return self.request(path, method="POST", body=json.dumps(data).encode(),
                            content_type="application/json").json()
