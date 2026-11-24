#!/usr/bin/env python3
"""A pretend ATEM switcher on UDP 9910, for testing CueVideo with no hardware.

    python3 Tools/fake_atem.py [port]

Speaks enough of the ATEM protocol to connect, send its state, take every
command CueVideo sends, and echo the changes back. Prints each command.
Also answers as three VISCA over IP cameras on UDP 52381-52383 (--cams).
"""
import socket, struct, sys, threading, time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 9910
ACKREQ, HELLO, RESEND, RESENDREQ, ACK = 0x01, 0x02, 0x04, 0x08, 0x10

def cmd(name, data=b""):
    return struct.pack(">HH", 8 + len(data), 0) + name.encode() + data

INPUTS = {0: ("Black", "BLK"), 1: ("Center Camera", "CAM1"), 2: ("Left Camera", "CAM2"), 3: ("Right Camera", "CAM3"),
          4: ("ProPresenter", "PRO"), 5: ("Walk-in Loop", "LOOP"), 6: ("Stage Camera", "STG"),
          1000: ("Color Bars", "BARS"), 2001: ("Color 1", "COL1"), 2002: ("Color 2", "COL2"),
          3010: ("Media Player 1", "MP1"), 3011: ("Media Player 1 Key", "MP1K"), 3020: ("Media Player 2", "MP2"),
          7001: ("Clean Feed 1", "CFD1"), 10010: ("Program", "PGM"), 10011: ("Preview", "PVW")}

class Switcher:
    def __init__(self, *, host="0.0.0.0"):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind((host, PORT))
        self.lock = threading.Lock()
        self.client = None
        self.pid = 0
        self.session = 0x8001
        self.prog, self.prev = 1, 2
        self.pos, self.intrans = 0, False
        self.style, self.nextsel, self.rate = 0, 1, 30
        self.keys = {0: False, 1: False}
        self.dsk = {0: [False, False, False], 1: [False, False, False]}  # on air, in transition, tie
        self.ftb, self.ftbtrans = False, False
        self.aux = {0: 4, 1: 3, 2: 3, 3: 10010, 4: 10010, 5: 10010, 6: 10010, 7: 10010, 8: 10010, 9: 1, 10: 2, 11: 10010}
        self.macros = {0: "Walk-in", 1: "Service Start", 3: "Pastor Wide"}
        self.macro = None
        self.stream, self.record = 1, 0

    def packet(self, flags, payload=b"", ackid=0):
        with self.lock:
            if flags & ACKREQ:
                self.pid = (self.pid + 1) % 32768
            pid = self.pid if flags & ACKREQ else 0
            n = 12 + len(payload)
            hdr = bytes([(flags << 3) | ((n >> 8) & 7), n & 0xFF, self.session >> 8, self.session & 0xFF,
                         ackid >> 8, ackid & 0xFF, 0, 0, 0, 0, pid >> 8, pid & 0xFF])
            if self.client:
                self.sock.sendto(hdr + payload, self.client)

    def send(self, cmds):
        buf = b""
        for c in cmds:
            if len(buf) + len(c) > 1300:
                self.packet(ACKREQ, buf); buf = b""
            buf += c
        if buf:
            self.packet(ACKREQ, buf)

    # State as commands
    def c_inputs(self):
        out = []
        for i, (l, s) in INPUTS.items():
            out.append(cmd("InPr", struct.pack(">H", i) + l.encode().ljust(20, b"\0") + s.encode().ljust(4, b"\0") + bytes(10)))
        return out
    def c_bus(self): return [cmd("PrgI", struct.pack(">BBH", 0, 0, self.prog)), cmd("PrvI", struct.pack(">BBHBBBB", 0, 0, self.prev, 0, 0, 0, 0))]
    def c_trps(self): return [cmd("TrPs", struct.pack(">BBBBHBB", 0, int(self.intrans), 0, 0, int(self.pos * 10000), 0, 0))]
    def c_trss(self): return [cmd("TrSS", struct.pack(">BBBBBBBB", 0, self.style, self.nextsel, self.style, self.nextsel, 0, 0, 0))]
    def c_rate(self): return [cmd("TMxP", struct.pack(">BBBB", 0, self.rate, 0, 0))]
    def c_keys(self): return [cmd("KeOn", struct.pack(">BBBB", 0, k, int(v), 0)) for k, v in self.keys.items()]
    def c_dsk(self):
        out = []
        for d, (on, tr, tie) in self.dsk.items():
            out.append(cmd("DskS", struct.pack(">BBBBBBBB", d, int(on), int(tr), int(tr), 0, 0, 0, 0)))
            out.append(cmd("DskP", struct.pack(">BBBBBBBB", d, int(tie), 25, 0, 0, 0, 0, 0)))
        return out
    def c_ftb(self): return [cmd("FtbS", struct.pack(">BBBB", 0, int(self.ftb), int(self.ftbtrans), 0))]
    def c_aux(self): return [cmd("AuxS", struct.pack(">BBH", a, 0, s)) for a, s in self.aux.items()]
    def c_macros(self):
        out = []
        for i in range(4):
            n = self.macros.get(i, "").encode()
            out.append(cmd("MPrp", struct.pack(">HBBHH", i, int(i in self.macros), 0, len(n), 0) + n + bytes((4 - len(n) % 4) % 4)))
        return out
    def c_mrun(self): return [cmd("MRPr", struct.pack(">BBH", int(self.macro is not None), 0, self.macro if self.macro is not None else 0xFFFF))]
    def c_stream(self): return [cmd("StRS", struct.pack(">HH", self.stream, 0))]
    def c_record(self): return [cmd("RTMS", struct.pack(">HHI", self.record, 0, 0))]
    def c_tally(self):
        ids = sorted(i for i in INPUTS if i < 10000)
        data = struct.pack(">H", len(ids))
        for i in ids:
            f = (1 if i == self.prog else 0) | (2 if i == self.prev else 0)
            if self.keys[0] and i == 3010: f |= 1
            data += struct.pack(">HB", i, f)
        return [cmd("TlSr", data + bytes((4 - len(data) % 4) % 4))]

    def dump(self):
        self.send([cmd("_ver", struct.pack(">HH", 2, 30)), cmd("_pin", b"ATEM Constellation HD (fake)".ljust(44, b"\0"))]
                  + self.c_inputs() + self.c_bus() + self.c_trps() + self.c_trss() + self.c_rate() + self.c_keys()
                  + self.c_dsk() + self.c_ftb() + self.c_aux() + self.c_macros() + self.c_mrun() + self.c_stream()
                  + self.c_record() + self.c_tally() + [cmd("InCm", bytes(4))])

    def later(self, secs, fn):
        threading.Timer(secs, fn).start()

    def swap(self):
        self.prog, self.prev = self.prev, self.prog

    def auto(self):
        if self.intrans: return
        def run():
            self.intrans = True
            frames = max(1, self.rate)
            for f in range(1, frames + 1):
                self.pos = f / frames
                self.send(self.c_trps())
                time.sleep(1 / 30)
            self.intrans, self.pos = False, 0
            self.swap()
            self.send(self.c_bus() + self.c_trps() + self.c_tally())
        threading.Thread(target=run, daemon=True).start()

    def handle(self, name, d):
        u16 = lambda i: struct.unpack(">H", d[i:i + 2])[0]
        print("RX", name, d.hex(" "), flush=True)
        if name == "CPgI": self.prog = u16(2); self.send(self.c_bus() + self.c_tally())
        elif name == "CPvI": self.prev = u16(2); self.send(self.c_bus() + self.c_tally())
        elif name == "DCut": self.swap(); self.send(self.c_bus() + self.c_tally())
        elif name == "DAut": self.auto()
        elif name == "CTPs":
            p = u16(2) / 10000
            if p >= 1:
                self.pos = 1; self.send(self.c_trps())
                self.intrans, self.pos = False, 0; self.swap()
                self.send(self.c_bus() + self.c_trps() + self.c_tally())
            elif p <= 0:
                self.intrans, self.pos = False, 0; self.send(self.c_trps())
            else:
                self.intrans, self.pos = True, p; self.send(self.c_trps())
        elif name == "CTTp":
            if d[0] & 1: self.style = d[2]
            if d[0] & 2: self.nextsel = d[3]
            self.send(self.c_trss())
        elif name == "CTMx": self.rate = d[1]; self.send(self.c_rate())
        elif name == "CKOn": self.keys[d[1]] = bool(d[2]); self.send(self.c_keys() + self.c_tally())
        elif name == "CDsL": self.dsk[d[0]][0] = bool(d[1]); self.send(self.c_dsk())
        elif name == "CDsT": self.dsk[d[0]][2] = bool(d[1]); self.send(self.c_dsk())
        elif name == "DDsA":
            i = d[0]; self.dsk[i][1] = True; self.send(self.c_dsk())
            def done(): self.dsk[i][1] = False; self.dsk[i][0] = not self.dsk[i][0]; self.send(self.c_dsk())
            self.later(0.8, done)
        elif name == "FtbA":
            self.ftbtrans = True; self.send(self.c_ftb())
            def done(): self.ftbtrans = False; self.ftb = not self.ftb; self.send(self.c_ftb())
            self.later(0.8, done)
        elif name == "CAuS": self.aux[d[1]] = u16(2); self.send(self.c_aux())
        elif name == "MAct":
            i = u16(0)
            if i == 0xFFFF: self.macro = None; self.send(self.c_mrun())
            elif i in self.macros:
                self.macro = i; self.send(self.c_mrun())
                def done(): self.macro = None; self.send(self.c_mrun())
                self.later(1.5, done)
        elif name == "StrR":
            if d[0]:
                self.stream = 2; self.send(self.c_stream())
                def up(): self.stream = 4; self.send(self.c_stream())
                self.later(1.0, up)
            else: self.stream = 1; self.send(self.c_stream())
        elif name == "RcTM": self.record = 1 if d[0] else 0; self.send(self.c_record())

    def ping(self):
        while True:
            time.sleep(0.5)
            if self.client: self.packet(ACKREQ)

    def run(self):
        threading.Thread(target=self.ping, daemon=True).start()
        print(f"Fake ATEM listening on UDP {PORT}", flush=True)
        while True:
            b, addr = self.sock.recvfrom(2048)
            if len(b) < 12: continue
            flags = b[0] >> 3
            n = ((b[0] & 7) << 8) | b[1]
            if flags & HELLO:
                self.client = addr; self.pid = 0
                print("HELLO from", addr, flush=True)
                hdr = bytes([(HELLO << 3), 20, 0x53, 0xAB, 0, 0, 0, 0, 0, 0, 0, 0])
                self.sock.sendto(hdr + bytes([2, 0, 0, 1, 0, 0, 0, 0]), addr)
                self.later(0.05, self.dump)
                continue
            if flags & ACKREQ:
                cid = (b[10] << 8) | b[11]
                self.packet(ACK, ackid=cid)
                if flags & RESEND: print("(resent packet)", flush=True)
                off, p = 12, b[12:n]
                off = 0
                while off + 8 <= len(p):
                    ln = struct.unpack(">H", p[off:off + 2])[0]
                    if ln < 8: break
                    self.handle(p[off + 4:off + 8].decode("ascii", "replace"), p[off + 8:off + ln])
                    off += ln

def fake_cams():
    def cam(port):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("0.0.0.0", port))
        while True:
            b, addr = s.recvfrom(256)
            if len(b) >= 8 and b[0] == 0x01:
                body = b[8:]
                print(f"CAM{port - 52380} VISCA", body.hex(" "), flush=True)
                seq = b[4:8]
                s.sendto(bytes([0x01, 0x11, 0, 3]) + seq + bytes([0x90, 0x41, 0xFF]), addr)  # ACK
                s.sendto(bytes([0x01, 0x11, 0, 3]) + seq + bytes([0x90, 0x51, 0xFF]), addr)  # done
            elif b[:2] == bytes([0x02, 0x00]):
                s.sendto(bytes([0x02, 0x01, 0, 1, 0, 0, 0, 0, 0x01]), addr)
    for p in (52381, 52382, 52383):
        threading.Thread(target=cam, args=(p,), daemon=True).start()

if __name__ == "__main__":
    if "--cams" in sys.argv: fake_cams()
    Switcher().run()
