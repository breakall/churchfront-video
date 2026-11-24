"""Command-line and interactive entry points; no Churchfront dependencies."""

import argparse
import json
import os
from pathlib import Path
import shlex
import signal
import sys
import tempfile
import threading

from .camera import CameraSimulator
from .controller import Controller
from .scenarios import verify


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(value, stream, indent=2, ensure_ascii=False)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if temporary and temporary.exists():
            temporary.unlink()


def action_parser(parser):
    actions = parser.add_subparsers(dest="action", required=True)
    actions.add_parser("info").add_argument("--item")
    for axis, choices in (("pan", ("left", "right", "stop")),
                          ("tilt", ("down", "up", "stop")),
                          ("zoom", ("tele", "wide", "stop"))):
        action = actions.add_parser(axis)
        action.add_argument("direction", choices=choices)
        action.add_argument("--speed", type=int, default=10 if axis == "zoom" else 100)
    focus = actions.add_parser("focus")
    focus.add_argument("value", choices=("near", "far", "stop", "one_shot", "auto", "manual"))
    for name in ("preset-store", "preset-recall"):
        action = actions.add_parser(name)
        action.add_argument("number", type=int)
        if name == "preset-store":
            action.add_argument("--name", default="")
    for name, choices in (("trace-record", ("start", "stop", "cancel")),
                          ("trace-play", ("prepare", "start", "stop"))):
        action = actions.add_parser(name)
        action.add_argument("value", choices=choices)
        action.add_argument("--number", type=int)
        if name == "trace-record":
            action.add_argument("--name", default="")
    raw = actions.add_parser("raw")
    raw.add_argument("endpoint")
    raw.add_argument("--param", action="append", default=[])
    raw.add_argument("--method", choices=("GET", "POST"), default="GET")
    actions.add_parser("claim")
    actions.add_parser("release")
    actions.add_parser("shell")


def perform(controller, args):
    action = args.action
    if action == "info":
        return controller.info(args.item)
    if action in ("pan", "tilt"):
        return controller.command("control.cgi", {action: args.direction, action + ".speed": args.speed})
    if action == "zoom":
        return controller.zoom(args.direction, args.speed)
    if action == "focus":
        if args.value in ("auto", "manual"):
            return controller.command("control.cgi", {"focus": args.value})
        return controller.focus(args.value)
    if action == "preset-store":
        return controller.preset_store(args.number, args.name)
    if action == "preset-recall":
        return controller.preset_recall(args.number)
    if action == "trace-record":
        return controller.trace_record(args.value, args.number, args.name)
    if action == "trace-play":
        return controller.trace_play(args.value, args.number)
    if action == "claim":
        return controller.claim()
    if action == "release":
        return controller.release()
    if action == "raw":
        values = {}
        for item in args.param:
            key, separator, value = item.partition("=")
            if not separator or not key or key in values:
                raise ValueError("use unique --param key=value entries")
            values[key] = value
        return controller.command(args.endpoint, values, method=args.method)
    raise ValueError("unknown controller action")


def show_reply(reply):
    fields = {key: value for key, value in reply.fields.items() if key != "s"}
    print(json.dumps({"http_status": reply.status, "livescope": reply.livescope,
                      "fields": fields}, ensure_ascii=False, indent=2))
    return 0 if reply.status == 200 and reply.livescope == "0" else 1


def shell(controller):
    parser = argparse.ArgumentParser(prog="controller")
    action_parser(parser)
    print("Virtual RC-IP100. Enter help, a controller action, or quit. Movement needs an explicit stop.")
    while True:
        try:
            line = input("rc-ip100> ").strip()
            if line in ("quit", "exit"):
                return 0
            if line == "help":
                parser.print_help()
            elif line:
                args = parser.parse_args(shlex.split(line))
                if args.action == "shell":
                    continue
                show_reply(perform(controller, args))
        except (EOFError, KeyboardInterrupt):
            return 0
        except SystemExit:
            continue
        except Exception as error:
            print(f"{type(error).__name__}: {error}", file=sys.stderr)


def parser_for_cli():
    parser = argparse.ArgumentParser(description="Loopback-only camera/controller test rig; Python standard library only.")
    commands = parser.add_subparsers(dest="command", required=True)
    camera = commands.add_parser("camera", help="start a simulated camera")
    camera.add_argument("--port", type=int, default=18081)
    camera.add_argument("--clock", choices=("manual", "realtime"), default="realtime")
    camera.add_argument("--ownership", choices=("documented", "exclusive"), default="documented")
    camera.add_argument("--ready-file")
    control = commands.add_parser("controller", help="send controller actions or open an interactive shell")
    control.add_argument("--target", required=True)
    control.add_argument("--actor", choices=("controller", "software"), default="controller")
    control.add_argument("--sessionless", action="store_true")
    control.add_argument("--timeout", type=float, default=2)
    action_parser(control)
    inspect = commands.add_parser("inspect", help="read simulator metadata, state or sanitized request history")
    inspect.add_argument("--camera", required=True)
    inspect.add_argument("what", choices=("meta", "state", "events"))
    advance = commands.add_parser("advance", help="advance a camera's manual simulation clock")
    advance.add_argument("--camera", required=True)
    advance.add_argument("seconds", type=float)
    fault = commands.add_parser("fault", help="arm a simulated camera failure")
    fault.add_argument("--camera", required=True)
    fault.add_argument("mode", choices=("http", "livescope", "delay", "delay_after", "disconnect", "malformed", "stream"))
    fault.add_argument("--endpoint", default="*")
    fault.add_argument("--code", type=int)
    fault.add_argument("--seconds", type=float, default=0.1)
    fault.add_argument("--count", type=int, default=1)
    for name in ("selftest", "verify"):
        command = commands.add_parser(name, help="run repeatable network scenarios and save a JSON report")
        command.add_argument("--output", default=".camera-rig/last-report.json")
        if name == "verify":
            command.add_argument("--target", required=True, help="bridge's controller-facing loopback URL")
            command.add_argument("--camera", required=True, help="simulated camera's inspection URL")
        else:
            command.add_argument("--ownership", choices=("documented", "exclusive"), default="documented")
    bridge = commands.add_parser("bridge-test", help="launch and verify an actual bridge executable")
    bridge.add_argument("--bridge-binary", required=True)
    bridge.add_argument("--ownership", choices=("both", "documented", "exclusive"), default="both")
    bridge.add_argument("--transport-only", action="store_true", help="run the first forwarding milestone only")
    bridge.add_argument("--output", default=".camera-rig/bridge-report.json")
    return parser


def main(argv=None):
    args = parser_for_cli().parse_args(argv)
    try:
        if args.command == "camera":
            if not 0 <= args.port <= 65535:
                raise ValueError("port must be between 0 and 65535")
            stop = threading.Event()
            old_handler = signal.signal(signal.SIGTERM, lambda *_: stop.set())
            try:
                with CameraSimulator(clock=args.clock, port=args.port, ownership=args.ownership) as camera:
                    ready = {"event": "camera_ready", "url": camera.url, "clock": args.clock,
                             "ownership": args.ownership, "simulated": True}
                    if args.ready_file:
                        write_json(args.ready_file, ready)
                    print(json.dumps(ready), flush=True)
                    stop.wait()
            finally:
                signal.signal(signal.SIGTERM, old_handler)
            return 0
        if args.command == "controller":
            with Controller(args.target, timeout=args.timeout, actor=args.actor) as controller:
                try:
                    if not args.sessionless:
                        controller.connect().require_ok()
                    return shell(controller) if args.action == "shell" else show_reply(perform(controller, args))
                finally:
                    if controller.session:
                        controller.release().require_ok()
        if args.command in ("inspect", "advance", "fault"):
            with Controller(args.camera) as admin:
                if admin.admin("meta").get("kind") != "canon-camera-test-rig":
                    raise ValueError("not a camera test rig")
                if args.command == "inspect":
                    result = admin.admin(args.what)
                elif args.command == "advance":
                    result = admin.admin("advance", {"seconds": args.seconds})
                else:
                    data = {"mode": args.mode, "endpoint": args.endpoint, "seconds": args.seconds, "count": args.count}
                    if args.code is not None:
                        data["code"] = args.code
                    result = admin.admin("fault", data)
                print(json.dumps(result, indent=2, ensure_ascii=False))
                return 0
        if args.command == "bridge-test":
            from .bridge_scenarios import verify_bridge
            report = verify_bridge(args.bridge_binary, ownership=args.ownership, transport_only=args.transport_only)
        elif args.command == "selftest":
            with CameraSimulator(clock="manual", ownership=args.ownership) as camera:
                report = verify(camera.url, camera.url)
        else:
            report = verify(args.target, args.camera)
        write_json(args.output, report)
        for check in report["checks"]:
            print(f"{'PASS' if check['passed'] else 'FAIL'} {check['name']} ({check['duration_ms']:.1f} ms)")
            if not check["passed"]:
                print("  " + check["error"])
        print(f"Report: {Path(args.output).resolve()}")
        print("Scope: " + report["mode"] + "; actual Churchfront tracking adapter is not yet under test.")
        return 0 if report["passed"] else 1
    except KeyboardInterrupt:
        return 130
    except Exception as error:
        print(f"ERROR {type(error).__name__}: {error}", file=sys.stderr)
        return 2
