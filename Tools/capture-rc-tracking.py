#!/usr/bin/env python3
"""Capture one RC-IP100 tracking rehearsal and index HTTP exchanges by operator action."""
import argparse
from datetime import datetime, timezone
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from urllib.parse import parse_qsl, urlsplit
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]
RUNS = ROOT / ".camera-rig" / "tracking-captures"
CONFIG = Path.home() / "Library/Application Support/CueVideo/CameraBridge/helper.json"
TCPDUMP = "/usr/sbin/tcpdump"
PHASES = ("baseline", "menu", "start", "stop")
WORDS = set("auto manual on off start stop enable disable enabled disabled true false active inactive ready idle running supported unsupported".split())


def program(name):
    path = shutil.which(name)
    if not path:
        raise ValueError(f"{name} is required (brew install wireshark).")
    return path


def save(path, obj):
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as out:
        json.dump(obj, out, indent=2)
        out.write("\n")
    os.replace(out.name, path)


def capture_filter(controller, bridge, port):
    client, server = ipaddress.IPv4Address(controller), ipaddress.IPv4Address(bridge)
    if not 1 <= port <= 65535 or client.is_unspecified or server.is_unspecified or client == server:
        raise ValueError("Provide the RC-IP100 address, the Mac's specific listener address, and its TCP port.")
    return (f"tcp and ((src host {client} and dst host {server} and dst port {port}) or "
            f"(src host {server} and src port {port} and dst host {client}))")


def safe_field(key, value):
    # The private pcap retains the original bytes when an unfamiliar value needs inspection.
    if not re.fullmatch(r"[a-zA-Z][a-zA-Z0-9_.-]{0,95}", key):
        return ["<unknown field>", "<omitted>"]
    if key.lower() == "s" or re.search(r"pass|secret|session|token|auth|credential|cookie|nonce|user|key", key, re.I):
        value = "<redacted>"
    elif key == "item" and re.fullmatch(r"[a-zA-Z0-9_.*,!-]{1,256}", value):
        pass
    elif value.lower() not in WORDS and not re.fullmatch(r"-?[0-9]{1,5}", value):
        value = "<omitted>"
    return [key, value]


def decode(folder):
    meta = json.loads((folder / "markers.json").read_text())
    port = meta["bridge_port"]
    cmd = [program("tshark"), "-n", "-2", "-r", str(folder / "controller.pcap"),
           "-d", f"tcp.port=={port},http", "-Y", "http.request || http.response", "-T", "pdml"]
    rows = []
    request_phases = {}
    # PDML includes raw protocol bytes. Only the selected fields below go to the index.
    with subprocess.Popen(cmd, stdout=subprocess.PIPE) as proc:
        for _, packet in ElementTree.iterparse(proc.stdout, events=("end",)):
            if packet.tag != "packet":
                continue
            fields = {}
            for field in packet.iter("field"):
                fields.setdefault(field.get("name"), []).append(field)

            def first(name):
                return fields[name][0].get("show", "") if name in fields else ""

            ts = float(first("frame.time_epoch"))
            phase = next((p["phase"] for p in reversed(meta["markers"]) if p["time"] <= ts), "pre-baseline")
            frame = first("frame.number")
            row = dict(frame=int(frame), time=ts, phase=phase, stream=first("tcp.stream"))
            if first("http.request.method"):
                uri = urlsplit(first("http.request.uri"))
                row.update(method=first("http.request.method"), path=uri.path,
                           query=[safe_field(k, v) for k, v in parse_qsl(uri.query, keep_blank_values=True)])
                form = fields.get("urlencoded-form.key", [])
                vals = fields.get("urlencoded-form.value", [])
                if form:
                    row["form"] = [safe_field(k.get("show", ""), v.get("show", "")) for k, v in zip(form, vals)]
                request_phases[frame] = phase
            if first("http.response.code"):
                request = first("http.request_in")
                row.update(http=int(first("http.response.code")), request_frame=int(request) if request else None,
                           request_phase=request_phases.get(request))
                for header in fields.get("http.response.line", []):
                    match = re.match(r"livescope-status:\s*(\d{1,3})\b", header.get("show", ""), re.I)
                    if match:
                        row["livescope"] = int(match[1])
                state = []
                for body in fields.get("http.file_data", []):
                    raw = body.get("value", "")
                    for line in bytes.fromhex(raw[:131072]).decode("utf-8", "replace").splitlines():
                        pair = re.fullmatch(r"([\w.-]{1,96})(?::=|==)(.*)", line)
                        if pair:
                            state.append(safe_field(*pair.groups()))
                            if len(state) >= 256:
                                break
                if state:
                    row["reply_fields"] = state
            rows.append(row)
            packet.clear()
        if proc.wait() != 0:
            raise ValueError("TShark could not decode the capture. The original file is preserved.")
    counts = {p: sum(r.get("method") is not None and r["phase"] == p for r in rows) for p in PHASES}
    report = dict(source=meta["source"], termination=meta["termination"], capture_stats=meta.get("capture_stats"),
                  requests_by_window=counts, exchanges=rows)
    save(folder / "exchanges.json", report)
    print(f"{meta['source']} requests by window: {counts}\n{folder / 'exchanges.json'}", flush=True)
    if not any(counts.values()):
        print("No controller HTTP requests decoded. Check the slot, listener address, interface and capture timing.")
    return report


def new_run(source):
    RUNS.mkdir(mode=0o700, parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return Path(tempfile.mkdtemp(prefix=f"{source}-{stamp}-", dir=RUNS))


def record(args):
    config = json.loads(CONFIG.read_text()) if CONFIG.exists() else {}
    controller = args.controller or config.get("controllerAddress")
    bridge = args.bridge or config.get("listenHost")
    port = args.port if args.port is not None else config.get("controllerPort")
    if not controller or not bridge or port is None:
        raise ValueError("No saved bridge route. Supply --controller RC_IP --bridge MAC_IP --port LISTENER_PORT.")
    bpf = capture_filter(controller, bridge, port)
    interface = args.interface
    if not interface:
        route = subprocess.check_output(["/sbin/route", "-n", "get", controller], text=True)
        match = re.search(r"^\s*interface:\s*(\S+)\s*$", route, re.M)
        if not match:
            raise ValueError("Cannot determine capture interface. Supply --interface.")
        interface = match[1]
    interface_info = subprocess.check_output(["/sbin/ifconfig", interface], text=True)
    if bridge not in re.findall(r"^\s*inet (\S+)", interface_info, re.M):
        raise ValueError(f"Mac listener address {bridge} is not assigned to {interface}. Check the bridge slot and --interface.")
    program("tshark")
    if not sys.stdin.isatty():
        raise ValueError("Use an interactive terminal to mark the three button actions.")
    if os.geteuid() == 0:
        raise ValueError("Run as your usual user. Only tcpdump needs capture permission.")
    cmd = [TCPDUMP, "-i", interface, "-p", "-n", "-U", "-s", "0", "-c", "8192", "-w", "-", bpf]
    print(f"Controller {controller} ↔ Mac {bridge}:{port} on {interface}", flush=True)
    if not any(os.access(path, os.R_OK | os.W_OK) for path in Path("/dev").glob("bpf[0-9]*")):
        subprocess.run(["/usr/bin/sudo", "-v"], check=True)
        cmd = ["/usr/bin/sudo", "-n", *cmd[:1], "-Z", pwd.getpwuid(os.getuid()).pw_name, *cmd[1:]]
    folder = new_run("hardware")
    meta = dict(source="hardware", controller=controller, bridge=bridge, bridge_port=port,
                interface=interface, filter=bpf, markers=[], termination="initializing")
    raw = folder / "controller.pcap"
    prompts = ["Open the tracking menu", "Press Start once", "Press Stop once"]
    print(f"Private capture folder: {folder}", flush=True)
    log_path = folder / "capture.log"
    with raw.open("xb") as data, log_path.open("xb") as log:
        # A separate process group lets us stop both sudo and tcpdump. Keep the
        # controlling terminal for the cached sudo ticket; only this tool reads input.
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=data, stderr=log,
                                preexec_fn=os.setpgrp, env={**os.environ, "LC_ALL": "C"})
        try:
            deadline = time.monotonic() + 8
            while b"listening on " not in log_path.read_bytes()[:8192]:
                if proc.poll() is not None or time.monotonic() >= deadline:
                    raise ValueError(f"Capture did not start. See {folder / 'capture.log'}")
                time.sleep(0.05)
            meta["markers"].append(dict(phase="baseline", time=time.time()))
            meta["termination"] = "in progress"
            save(folder / "markers.json", meta)
            print("Recording. Leave the controller idle for a few seconds.", flush=True)
            deadline = time.monotonic() + 180
            for index in range(len(prompts) + 1):
                if index < len(prompts):
                    print(f"Press Return immediately before you {prompts[index].lower()}.", flush=True)
                else:
                    print("Let the Stop reply settle, then press Return to finish.", flush=True)
                while proc.poll() is None and time.monotonic() < deadline and raw.stat().st_size < 16 * 1024**2:
                    if select.select([sys.stdin], [], [], 0.1)[0]:
                        if not sys.stdin.readline():
                            raise EOFError
                        break
                else:
                    meta["termination"] = "capture ended early or reached its limit"
                    break
                if index < 3:
                    meta["markers"].append(dict(phase=PHASES[index+1], time=time.time()))
                    save(folder / "markers.json", meta)
                    print(f"Now: {prompts[index]}.", flush=True)
                else:
                    meta["termination"] = "operator finished"
        except (KeyboardInterrupt, EOFError):
            meta["termination"] = "operator interrupted"
        finally:
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGINT)
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGTERM)
                    proc.wait(timeout=5)
                except ProcessLookupError:
                    proc.wait()
            meta["capture_exit"] = proc.returncode
            stats = re.findall(r"(?m)^(\d+) packets? (captured|received by filter|dropped by kernel)", log_path.read_text(errors="replace"))
            meta["capture_stats"] = {label: int(number) for number, label in stats}
            save(folder / "markers.json", meta)
    report = decode(folder)
    if meta["capture_stats"].get("dropped by kernel", 0):
        print("The kernel dropped packets. This capture may be incomplete.")
    if meta["capture_exit"] not in (0, -signal.SIGINT):
        raise ValueError(f"Capture exited with status {meta['capture_exit']}. See {log_path}.")
    if any(count == 0 for count in report["requests_by_window"].values()):
        print("An empty window can mean the menu used cached state, a press sent no request, or traffic missed this interface. Inspect the private capture.")
    return 0 if meta["termination"] == "operator finished" and any(report["requests_by_window"].values()) else 1


def rehearse():
    folder = new_run("synthetic")
    port = 18080
    ts = int(time.time()) - 15
    phases = [dict(phase=p, time=ts+i*2) for i, p in enumerate(PHASES)]
    fixture = []
    for i, phase in enumerate(PHASES):
        path = "/-wvhttp-01-/info.cgi?item=" + ("s.control" if i == 0 else "fixture.tracking.capability")
        body = "" if i < 2 else "fixture.action=" + phase
        method = "POST" if body else "GET"
        if body:
            path = "/-wvhttp-01-/control.cgi?s=fixture-private"
        request = (f"{method} {path} HTTP/1.1\r\nHost: fixture\r\nContent-Type: application/x-www-form-urlencoded\r\n"
                   f"Content-Length: {len(body)}\r\n\r\n{body}")
        state = f"fixture.tracking:={'on' if phase == 'start' else 'off'}\r\n"
        reply = f"HTTP/1.1 200 OK\r\nLivescope-Status: 0\r\nContent-Type: text/plain\r\nContent-Length: {len(state)}\r\n\r\n{state}"
        messages = [('I', request, 100), ('O', reply, 200)]
        if phase == "start":
            # The HTTP form is split across TCP segments, as it can be on the LAN.
            messages = [('I', request[:-2], 100), ('I', request[-2:], 150), ('O', reply, 200)]
        for d, message, ms in messages:
            when = datetime.fromtimestamp(ts+i*2+ms/1000, timezone.utc).isoformat()
            fixture.append(f"{d} {when}\n000000 {message.encode().hex(' ')}\n")
    subprocess.run([program("text2pcap"), "-q", "-D", "-t", "ISO", "-4", "192.0.2.19,192.0.2.8",
                    "-T", f"40123,{port}", "-F", "pcap", "-", str(folder / "controller.pcap")],
                   input="\n".join(fixture), text=True, check=True)
    save(folder / "markers.json", dict(source="synthetic", markers=phases, bridge_port=port, termination="fixture complete"))
    # Apply the exact live filter to the fixture with the system packet reader.
    bpf = capture_filter("192.0.2.19", "192.0.2.8", port)
    with subprocess.Popen([TCPDUMP, "-nn", "-r", str(folder / "controller.pcap"), bpf],
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as reader:
        matched = len(reader.stdout.readlines())
        if reader.wait() or matched != 9:
            raise RuntimeError(f"Capture filter only matched {matched} fixture packets")
    report = decode(folder)
    requests = [r for r in report["exchanges"] if "method" in r]
    replies = [r for r in report["exchanges"] if "http" in r]
    if (list(report["requests_by_window"].values()) != [1, 1, 1, 1]
            or [r.get("form") for r in requests[2:]] != [[["fixture.action", "start"]], [["fixture.action", "stop"]]]
            or ["item", "fixture.tracking.capability"] not in requests[1]["query"]
            or [r["request_phase"] for r in replies] != list(PHASES)
            or any(r.get("livescope") != 0 for r in replies)
            or ["fixture.tracking", "on"] not in replies[2].get("reply_fields", [])
            or "fixture-private" in json.dumps(report)):
        raise RuntimeError("Offline capture verification failed. Inspect the synthetic report.")
    print("Verified menu selector, segmented Start, Stop, associated replies and session redaction.")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    live = sub.add_parser("record")
    live.add_argument("--controller")
    live.add_argument("--bridge", help="Mac listener IPv4 address")
    live.add_argument("--port", type=int)
    live.add_argument("--interface")
    sub.add_parser("rehearse")
    review = sub.add_parser("decode")
    review.add_argument("folder", type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == "decode":
        decode(args.folder)
        return 0
    return record(args) if args.command == "record" else rehearse()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
