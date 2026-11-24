"""Small deterministic camera model, intentionally not a camera firmware clone."""

import math
import secrets
import time


class ProtocolError(Exception):
    def __init__(self, status, message):
        self.status = status
        super().__init__(message)


class CameraModel:
    LIMITS = {"pan": (-17000, 17000), "tilt": (-3000, 9000), "zoom": (570, 7300)}

    def __init__(self, clock, ownership="documented"):
        if clock not in ("manual", "realtime"):
            raise ValueError("clock must be manual or realtime")
        self.clock = clock
        if ownership not in ("documented", "exclusive"):
            raise ValueError("ownership must be documented or exclusive")
        self.ownership = ownership
        self.sessions = {}
        self.owner = None
        self.last_tick = time.monotonic()
        self.elapsed = 0.0
        self.pose = {"pan": 0.0, "tilt": 0.0, "zoom": 4000.0}
        self.velocity = {"pan": 0.0, "tilt": 0.0, "zoom": 0.0}
        self.presets = {}
        self.traces = {}
        self.recording = None
        self.playing = None
        self.prepared = None
        self.focus_action = "stop"
        self.focus_mode = "auto"
        self.focus_value = 0

    def step(self, seconds):
        if not math.isfinite(seconds) or not 0 <= seconds <= 3600:
            raise ValueError("seconds must be finite and between 0 and 3600")
        target = self.elapsed + seconds
        if self.playing:
            playback = self.playing
            trace = self.traces[playback["number"]]
            finish = playback["started"] + trace["duration"]
            while playback["index"] < len(trace["events"]):
                at, parameters = trace["events"][playback["index"]]
                event_time = playback["started"] + at
                if event_time > min(target, finish):
                    break
                self._integrate(max(0, event_time - self.elapsed))
                self.control(parameters)
                playback["index"] += 1
            self._integrate(max(0, min(target, finish) - self.elapsed))
            if target >= finish:
                self.playing = None
                self.velocity = dict.fromkeys(self.velocity, 0.0)
                self.focus_action = "stop"
        self._integrate(max(0, target - self.elapsed))

    def _integrate(self, seconds):
        self.elapsed += seconds
        for axis, speed in self.velocity.items():
            low, high = self.LIMITS[axis]
            self.pose[axis] = max(low, min(high, self.pose[axis] + seconds * speed))

    def tick(self):
        now = time.monotonic()
        if self.clock == "realtime":
            self.step(min(3600, now - self.last_tick))
        self.last_tick = now

    def info(self):
        result = {"s.hardware": "Canon CR-N500", "s.firmware": "SIMULATOR",
                  "s.system.status": "idle", "c.1.focus": self.focus_mode,
                  "c.1.focus.action": self.focus_action, "c.1.focus.value": str(self.focus_value),
                  "t.status": "recording" if self.recording else "playing" if self.playing else "prepared" if self.prepared else "idle"}
        for axis in self.pose:
            result[f"c.1.{axis}"] = str(round(self.pose[axis]))
            low, high = self.LIMITS[axis]
            moving = (self.velocity[axis] > 0 and self.pose[axis] < high
                      or self.velocity[axis] < 0 and self.pose[axis] > low)
            result[f"c.1.{axis}.status"] = str(int(moving))
        for number, preset in self.presets.items():
            result[f"p.{number}.name.utf8"] = preset["name"]
            result[f"p.{number}.content.ptz"] = "enabled"
        for number, trace in self.traces.items():
            result[f"t.{number}.name.utf8"] = trace["name"]
            result[f"t.{number}.recorded"] = "on"
            result[f"t.{number}.time"] = str(round(trace["duration"] * 1000))
        return result

    def control(self, parameters):
        normalized = {key.removeprefix("c.1."): value for key, value in parameters.items()}
        if len(normalized) != len(parameters):
            raise ProtocolError(403, "conflicting abbreviated/full parameters")
        parameters = normalized
        self.validate_control(parameters)
        if "p" in parameters:
            number = self.number(parameters["p"], 100)
            if number not in self.presets:
                raise ProtocolError(403, "preset has not been stored")
            self.pose = self.presets[number]["pose"].copy()
            self.velocity = dict.fromkeys(self.velocity, 0.0)
            return self.info()
        if self.recording:
            if len(self.recording["events"]) >= 2000:
                raise ProtocolError(408, "simulated trace event limit reached")
            self.recording["events"].append((self.elapsed - self.recording["started"], parameters.copy()))
        for key, value in parameters.items():
            if key == "focus.value":
                self.focus_value = int(value)
                continue
            if key == "focus.action":
                if value not in ("near", "far", "stop", "one_shot"):
                    raise ProtocolError(403, "invalid focus action")
                self.focus_action = value
                continue
            if key == "focus":
                if value not in ("auto", "manual"):
                    raise ProtocolError(403, "invalid focus mode")
                self.focus_mode = value
                continue
            if key not in self.pose:
                if key.endswith(".speed") or key == "s":
                    continue
                raise ProtocolError(401, "unsupported control parameter")
            if value == "stop":
                self.velocity[key] = 0
            elif value in {"pan": ("left", "right"), "tilt": ("down", "up"), "zoom": ("tele", "wide")}[key]:
                speed = int(parameters.get(key + ".speed", "10" if key == "zoom" else "100"))
                negative = value in ("left", "down", "tele")
                if key == "zoom":
                    speed = max(1, speed) * 10
                self.velocity[key] = -speed if negative else speed
            else:
                try:
                    position = int(value)
                except ValueError:
                    raise ProtocolError(403, "invalid position") from None
                self.pose[key] = float(position)
                self.velocity[key] = 0
        return self.info()

    def validate_control(self, parameters):
        for key, value in parameters.items():
            if key == "s":
                continue
            if key == "p":
                if self.number(value, 100) not in self.presets:
                    raise ProtocolError(403, "preset has not been stored")
            elif key == "focus.value":
                if not value.isdecimal() or not 0 <= int(value) <= 2048:
                    raise ProtocolError(403, "invalid focus position")
            elif key == "focus.action":
                if value not in ("near", "far", "stop", "one_shot"):
                    raise ProtocolError(403, "invalid focus action")
            elif key == "focus":
                if value not in ("auto", "manual"):
                    raise ProtocolError(403, "invalid focus mode")
            elif key in self.pose:
                directions = {"pan": ("left", "right", "stop"), "tilt": ("down", "up", "stop"),
                              "zoom": ("tele", "wide", "stop")}[key]
                if value not in directions:
                    try:
                        position = int(value)
                        low, high = self.LIMITS[key]
                        if not low <= position <= high:
                            raise ValueError()
                    except ValueError:
                        raise ProtocolError(403, "invalid position") from None
            elif key in ("pan.speed", "tilt.speed", "zoom.speed"):
                try:
                    speed = int(value)
                    low, high = (0, 127) if key == "zoom.speed" else (10, 10000)
                    if not low <= speed <= high:
                        raise ValueError()
                except ValueError:
                    raise ProtocolError(403, "invalid speed") from None
            else:
                raise ProtocolError(401, "unsupported control parameter")

    @staticmethod
    def number(value, maximum):
        if value is None:
            raise ProtocolError(406, "slot number is required")
        try:
            number = int(value)
        except ValueError:
            raise ProtocolError(403, "invalid slot number") from None
        if not 1 <= number <= maximum:
            raise ProtocolError(403, "slot number out of range")
        return number

    def preset_set(self, parameters):
        if "cmd" in parameters or parameters.get("all", "enabled") != "enabled":
            raise ProtocolError(403, "simulator supports complete preset storage only")
        if parameters.keys() - {"s", "p", "name", "all"}:
            raise ProtocolError(401, "unsupported preset parameter")
        number = self.number(parameters.get("p"), 100)
        self.presets[number] = {"pose": self.pose.copy(), "name": parameters.get("name", "")}
        return {"p": str(number), f"p.{number}.name.utf8": self.presets[number]["name"]}

    def session(self, endpoint, parameters):
        if endpoint == "open.cgi":
            if len(self.sessions) >= 32:
                raise ProtocolError(408, "simulated session limit reached")
            try:
                priority = int(parameters.get("s.priority", "0"))
                if not 0 <= priority <= 50:
                    raise ValueError()
            except ValueError:
                raise ProtocolError(403, "invalid priority") from None
            token = secrets.token_urlsafe(18)
            self.sessions[token] = priority
            return {"s": token, "s.priority": str(priority), "s.control": "disabled"}
        token = parameters.get("s")
        if token not in self.sessions:
            raise ProtocolError(501, "unknown session")
        if endpoint == "claim.cgi":
            if self.owner is None or self.sessions[token] >= self.sessions[self.owner]:
                self.owner = token
            return {"s.control": "enabled" if self.owner == token else "waiting"}
        if endpoint in ("yield.cgi", "close.cgi"):
            if self.owner == token:
                self.owner = None
            if endpoint == "close.cgi":
                del self.sessions[token]
            return {"s.control": "disabled"}
        raise ProtocolError(401, "unknown session operation")

    def authorize(self, parameters, *, write=False):
        token = parameters.get("s")
        if token is not None and token not in self.sessions:
            raise ProtocolError(501, "unknown session")
        if write and self.ownership == "exclusive" and (token is None or token != self.owner):
            raise ProtocolError(301, "control belongs to another session")

    def trace_set(self, parameters):
        command = parameters.get("cmd")
        if command == "start":
            number = self.number(parameters.get("t"), 10)
            if self.recording or self.playing:
                raise ProtocolError(408, "trace is busy")
            self.prepared = None
            self.recording = {"number": number, "name": parameters.get("name", ""),
                              "started": self.elapsed, "pose": self.pose.copy(), "events": []}
        elif command in ("stop", "cancel"):
            if not self.recording:
                raise ProtocolError(408, "trace is not recording")
            number = self.recording["number"]
            if command == "stop":
                trace = self.recording.copy()
                trace["duration"] = self.elapsed - trace["started"]
                self.traces[number] = trace
            self.recording = None
        else:
            raise ProtocolError(406 if command is None else 403, "unsupported trace record action")
        return {"t": str(number)}

    def trace_control(self, parameters):
        command = parameters.get("cmd")
        if command == "stop":
            self.playing = None
            self.prepared = None
            self.velocity = dict.fromkeys(self.velocity, 0.0)
            self.focus_action = "stop"
            return {"t": "0"}
        number = self.number(parameters.get("t"), 10)
        if self.recording:
            raise ProtocolError(408, "trace is recording")
        if number not in self.traces:
            raise ProtocolError(403, "trace has not been stored")
        if command == "prepare":
            self.pose = self.traces[number]["pose"].copy()
            self.velocity = dict.fromkeys(self.velocity, 0.0)
            self.playing = None
            self.prepared = number
        elif command == "start":
            if self.prepared != number:
                raise ProtocolError(408, "simulator requires prepare before playback")
            self.prepared = None
            self.playing = {"number": number, "started": self.elapsed, "index": 0}
        else:
            raise ProtocolError(406 if command is None else 403, "unsupported trace playback action")
        return {"t": str(number)}
