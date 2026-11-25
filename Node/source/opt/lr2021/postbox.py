#!/usr/bin/env python3
"""Postfach der LR2021 Node: die Node arbeitet auch ohne verbundenes Handy weiter.

  * hört an beiden Modems mit und speichert jedes empfangene Paket (rx.jsonl) – die App holt beim nächsten
    Verbinden alles ab, was sie verpasst hat, und wertet es wie live Empfangenes aus
  * LR-Funk (das Modul mit lr_role): Textbestätigungen, Dateien vollständig empfangen (fehlende Teile
    nachfordern, Bestätigung), eigene Dateiaufträge senden (ankündigen, mit voller erlaubter Leistung, nachsenden
    bis alle Empfänger vollständig sind, vorher warten, bis der Kanal frei ist)
  * Suche nach der ruhigsten Frequenz (Belegung über eine einstellbare Zeit)
  * Steuerkanal für die App: TCP 2024 (und Kanal 4 der Seriell-/Bluetooth-Brücke), eine JSON-Zeile je Nachricht

Das Protokoll der LR-Funk-Pakete entspricht App/source/lib/mesh/lr_radio.dart und lr_file.dart.
Nur Python-Standardbibliothek.
"""
import base64
import json
import logging
import os
import queue
import random
import socket
import struct
import threading
import time

from lrmodem import LrModem, ModemError, build_frame

log = logging.getLogger("lr2021d.postfach")

BOX_DIR = "/var/lib/lr2021/mailbox"
RX_KEEP = 5000                 # so viele empfangene Pakete bleiben gespeichert
CONTROL_PORT = 2024
MAX_LINE = 4 * 1024 * 1024     # größte Steuerzeile (Datei bis 1 MB als Base64)

LR_TEXT, LR_BEACON, LR_ACK, LR_FILE, LR_FILE_ACK, LR_OFFER, LR_ANNOUNCE = 1, 2, 3, 4, 5, 6, 7
CHUNK = 180
MAX_MISSING = 90
TXID_BASE = 0xC000             # tx_ids der Node (die App bleibt darunter)

SETTINGS_DEFAULT = {
    "callsign": "",            # ohne Rufzeichen sendet die Node nichts (Amateurfunk)
    "name": "",
    "num": 0,                  # eigene Knotennummer (wie in der App)
    "lr_role": "",             # Modul im LR-Funk-Betrieb ('A' oder 'B'), leer = Node beantwortet nichts
    "auto_ack": True,
    "twice": True,
    "clear": True,
    "loud_dbm": {},            # Rolle -> höchste erlaubte Leistung für Dateien (rechnet die App aus)
    "radio": {},               # Rolle -> zuletzt von der App eingestellte LoRa-Werte (nach ESP-Neustart wieder setzen)
}


# ============================================================== LR-Funk-Pakete
def lr_parse(raw):
    raw = bytes(raw)
    if len(raw) < 13 or raw[0] != 0x4C or raw[1] != 0x52 or raw[2] != 1:
        return None
    try:
        t = raw[3]
        frm, pid = struct.unpack_from("<II", raw, 4)
        i = 12
        cl = raw[i]
        i += 1
        call = raw[i:i + cl].decode("utf-8", "replace")
        if len(raw[i:i + cl]) != cl:
            return None
        i += cl
        nl = 0
        if i < len(raw):
            nl = raw[i]
            i += 1
        name = raw[i:i + nl].decode("utf-8", "replace")
        i += nl
        return {"type": t, "from": frm, "id": pid, "call": call, "name": name, "body": raw[i:]}
    except (IndexError, struct.error):
        return None


def lr_build(t, frm, pid, call, name, body):
    c, n = call.encode()[:12], name.encode()[:39]
    return b"LR\x01" + bytes([t]) + struct.pack("<II", frm & 0xFFFFFFFF, pid & 0xFFFFFFFF) + \
        bytes([len(c)]) + c + bytes([len(n)]) + n + bytes(body)


def chunk_parse(body):
    try:
        xfer, size, idx, count = struct.unpack_from("<IIHH", body, 0)
        if count == 0 or idx >= count:
            return None
        i, mime, name = 12, None, None
        if idx == 0:
            ml = body[i]
            mime = body[i + 1:i + 1 + ml].decode("utf-8", "replace")
            i += 1 + ml
            nl = body[i]
            name = body[i + 1:i + 1 + nl].decode("utf-8", "replace")
            i += 1 + nl
        return {"xfer": xfer, "size": size, "idx": idx, "count": count, "mime": mime, "name": name,
                "data": bytes(body[i:])}
    except (IndexError, struct.error):
        return None


def chunk_build(xfer, size, idx, count, data, mime="", name=""):
    out = struct.pack("<IIHH", xfer, size, idx, count)
    if idx == 0:
        m = mime[:40].encode()
        n = name.encode()
        if len(n) > 60:
            n = n[-60:]
        out += bytes([len(m)]) + m + bytes([len(n)]) + n
    return out + bytes(data)


def chunk_split(data, mime, name, xfer, size=CHUNK):
    """Wie FileChunk.split der App (Stück 0 ist kürzer, weil Name und Typ mitgehen)."""
    first = max(40, min(size, size - 2 - len(mime.encode()) - len(name.encode())))
    pieces = [data[:first]]
    o = len(pieces[0])
    while o < len(data):
        pieces.append(data[o:o + size])
        o += size
    n = len(pieces)
    return [chunk_build(xfer, len(data), i, n, pieces[i], mime, name) for i in range(n)]


def ack_parse(body):
    try:
        xfer, done, n = struct.unpack_from("<IBB", body, 0)
        miss = []
        i = 6
        for _ in range(n):
            if i + 2 > len(body):
                break
            miss.append(struct.unpack_from("<H", body, i)[0])
            i += 2
        total = struct.unpack_from("<H", body, i)[0] if i + 2 <= len(body) else len(miss)
        return {"xfer": xfer, "done": bool(done), "missing": miss, "total": max(total, len(miss))}
    except struct.error:
        return None


def ack_build(xfer, done, missing):
    m = list(missing)[:MAX_MISSING]
    return struct.pack("<IBB", xfer, 1 if done else 0, len(m)) + b"".join(struct.pack("<H", i) for i in m) + \
        struct.pack("<H", min(len(missing), 0xFFFF))


def announce_parse(body):
    try:
        xfer, size, count, air = struct.unpack_from("<IIHH", body, 0)
        i = 12
        ml = body[i]
        mime = body[i + 1:i + 1 + ml].decode("utf-8", "replace")
        i += 1 + ml
        nl = body[i]
        name = body[i + 1:i + 1 + nl].decode("utf-8", "replace")
        if count == 0:
            return None
        return {"xfer": xfer, "size": size, "count": count, "air": air, "mime": mime, "name": name}
    except (IndexError, struct.error):
        return None


def announce_build(xfer, size, count, air, mime, name):
    m = mime[:40].encode()
    n = name.encode()
    if len(n) > 60:
        n = n[-60:]
    return struct.pack("<IIHH", xfer, size, count, max(0, min(int(air), 0xFFFF))) + bytes([len(m)]) + m + \
        bytes([len(n)]) + n


def send_order(n, lag=8):
    """Wie fileSendOrder der App: jedes Teil zweimal, die zweite Kopie [lag] Teile später, das letzte einmal am Ende."""
    if n < 2:
        return list(range(n))
    out = []
    for i in range(n - 1):
        out.append(i)
        if i >= lag:
            out.append(i - lag)
    for i in range(max(0, n - 1 - lag), n - 1):
        out.append(i)
    out.append(n - 1)
    return out


class ResendPolicy:
    """Weiter nachsenden, solange es besser wird (wie ResendPolicy der App)."""

    def __init__(self, max_stall=4, max_rounds=80):
        self.max_stall, self.max_rounds = max_stall, max_rounds
        self.rounds = self.stall = 0
        self.best = None

    def next(self, missing):
        self.rounds += 1
        if self.best is None or missing < self.best:
            self.best, self.stall = missing, 0
        else:
            self.stall += 1
        return missing > 0 and self.stall < self.max_stall and self.rounds <= self.max_rounds


class ChannelWatch:
    """Grundrauschen merken; „belegt“, wenn der Pegel deutlich darüber liegt (auch Fremdsender ohne LoRa)."""

    def __init__(self, margin=12.0):
        self.margin = margin
        self.quiet = []

    @property
    def floor(self):
        if not self.quiet:
            return None
        s = sorted(self.quiet)
        return s[min(len(s) - 1, int(len(s) * 0.2))]

    def busy(self, rssi):
        f = self.floor
        b = rssi > f + self.margin if f is not None else rssi > -85
        if not b:
            self.quiet.append(rssi)
            if len(self.quiet) > 40:
                self.quiet.pop(0)
        return b


def quiet_windows(channels, width_khz, step_khz, n=10):
    """Ruhigste Fenster aus der Kanalliste (je Fenster: höchste Belegung und stärkstes Signal darin)."""
    k = max(1, int(round(width_khz / step_khz)))
    res = []
    for s in range(0, len(channels) - k + 1):
        part = channels[s:s + k]
        mid = (part[0]["mhz"] + part[-1]["mhz"]) / 2
        res.append((max(c["busy"] for c in part), max(c["max_db"] for c in part), round(mid, 4)))
    res.sort()
    out = []
    for r in res:
        if all(abs(r[2] - o[2]) * 1000 >= width_khz for o in out):
            out.append(r)
        if len(out) >= n:
            break
    return [{"mhz": m, "busy": b, "max_db": d} for b, d, m in out]


# ============================================================== Modem-Anbindung
class TapPort:
    """Tut für LrModem so, als wäre es ein serieller Anschluss – hängt aber als zusätzlicher Client am ModemLink
    von lr2021d (sieht alles, was das ESP32 sendet; Schreiben geht an das ESP32)."""

    def __init__(self, link):
        self.link = link
        self.q = queue.Queue()
        self._closed = False
        link.add_client(self, "Postfach")

    def sendall(self, data):            # vom ModemLink (broadcast)
        if not self._closed:
            self.q.put(bytes(data))

    def read(self, n):
        try:
            return self.q.get(timeout=0.5)
        except queue.Empty:
            return b""

    def write(self, data):
        self.link.write(data)

    def close(self):
        if self._closed:
            return
        self._closed = True
        self.link.remove_client(self)


class NodeModem(LrModem):
    """LrModem mit eigenem Bereich für Folgenummern (128–255), damit sich Antworten nicht mit denen der App
    (1–127) vermischen, die am selben ESP32 hängt."""

    def __init__(self, port, timeout=3.0):
        super().__init__(port, timeout=timeout)
        self._nseq = 127
        self._txid = 0

    def request(self, cmd, payload=b"", timeout=None):
        with self._lock:
            self._nseq = 128 if self._nseq >= 255 else self._nseq + 1
            seq = self._nseq
            slot = queue.Queue()
            self._pending[(cmd, seq)] = slot
        try:
            self.ser.write(build_frame(cmd, seq, payload))
            try:
                resp = slot.get(timeout=timeout or self.timeout)
            except queue.Empty:
                raise TimeoutError("keine Antwort vom Modem (Befehl 0x%02X)" % cmd)
        finally:
            with self._lock:
                self._pending.pop((cmd, seq), None)
        status = struct.unpack("<h", resp[:2])[0]
        if status != 0:
            raise ModemError(status, None, resp[2:])
        return resp[2:]

    def next_txid(self):
        self._txid = (self._txid + 1) % 0x4000
        return TXID_BASE + self._txid


def apply_cfg(m, c, power=None, freq_mhz=None):
    """LoRa-Einstellung aus einem config()-Ergebnis (oder den von der App gemeldeten Werten) setzen."""
    if "freq_hz" in c:                  # Format der App
        m.set_lora((freq_mhz or c["freq_hz"] / 1e6), c["bw_hz"] / 1e3, c["sf"], c["cr"], c["sync"],
                   c["power"] if power is None else power, c["preamble"], iq_inverted=bool(c.get("iq", False)))
    else:
        m.set_lora(freq_mhz or c["freq_mhz"], c["bw_khz"], c["sf"], int(str(c["cr"])[2:]), int(c["sync"], 16),
                   c["power_dbm"] if power is None else power, c["preamble"], crc=c.get("crc", True),
                   iq_inverted=c.get("iq_inverted", False), implicit_len=c.get("implicit_len") or 0)
    m.rx_start()


# ============================================================== Aufträge
class Job:
    _seq = 0

    def __init__(self, kind, role, **kw):
        Job._seq += 1
        self.id = "%d-%d" % (int(time.time()), Job._seq)
        self.kind, self.role = kind, role
        self.state, self.info, self.progress = "wartet", "", 0.0
        self.created = time.time()
        self.finished_at = None
        self.cancelled = False
        self.params = kw
        # Datei
        self.data = b""
        self.chunks = []
        self.sent = set()
        self.pending = set()
        self.missing_by = {}
        self.acked_by = []
        self.policy = ResendPolicy()
        self.round = self.probes = 0
        self.resume = False
        self.last_ack = 0.0
        self.result = None

    def public(self):
        d = {"id": self.id, "kind": self.kind, "role": self.role, "state": self.state, "info": self.info,
             "progress": round(self.progress, 3), "created": self.created, "finished": self.finished_at}
        if self.kind == "file":
            d.update(xfer=self.params.get("xfer"), name=self.params.get("name"), size=len(self.data),
                     parts=len(self.chunks), acked_by=list(self.acked_by),
                     missing_by=dict(self.missing_by), round=self.round)
        if self.kind == "scan":
            d.update(params={k: self.params.get(k) for k in ("from_mhz", "to_mhz", "bw_khz", "minutes")})
        return d


# ============================================================== Postfach
class Mailbox:
    def __init__(self, hub, cfg, box_dir=BOX_DIR):
        self.hub, self.cfg, self.dir = hub, cfg, box_dir
        self.node_id = ""              # setzt lr2021d (Kennung der Node, z. B. 6AEC)
        os.makedirs(os.path.join(box_dir, "files"), exist_ok=True)
        os.makedirs(os.path.join(box_dir, "jobs"), exist_ok=True)
        self.lock = threading.RLock()
        self.settings = dict(SETTINGS_DEFAULT)
        self.settings.update(cfg["mailbox"] or {})
        self.rx_path = os.path.join(box_dir, "rx.jsonl")
        self.last_id, self.rx_lines = self._scan_rx()
        self.rxq = queue.Queue()
        self.resp = {r: queue.Queue() for r in hub.links}
        self.jobs = []
        self.inx = {}
        self.done_x = {}
        self.seen = {}
        self.quiet_until = {r: 0.0 for r in hub.links}
        self.watch = {r: ChannelWatch() for r in hub.links}
        self.clients = []
        self.scanning = set()
        self.scan_result = self._load_json("scan.json")
        self.modems = {}
        for role, link in hub.links.items():
            m = NodeModem(TapPort(link))
            m.on_rx = (lambda ev, r=role: self.rxq.put((r, ev)))
            m.on_boot = (lambda ev, r=role: threading.Thread(target=self._on_boot, args=(r,), daemon=True).start())
            self.modems[role] = m
        self._load_jobs()

    # ---------------------------------------------------------------- Start
    def start(self, port=CONTROL_PORT):
        threading.Thread(target=self._rx_loop, daemon=True).start()
        for role in self.modems:
            threading.Thread(target=self._worker, args=(role,), daemon=True).start()
        threading.Thread(target=self._serve_tcp, args=(port,), daemon=True).start()
        threading.Thread(target=self._housekeeping, daemon=True).start()
        log.info("Postfach bereit (%d gespeicherte Pakete, Steuerkanal TCP %d)", self.rx_lines, port)

    def status(self):
        with self.lock:
            return {"pakete": self.rx_lines, "letzte_id": self.last_id,
                    "auftraege": [j.public() for j in self.jobs if j.finished_at is None],
                    "lr_modul": self.settings.get("lr_role"), "rufzeichen": self.settings.get("callsign"),
                    "app_verbunden": len(self.clients), "suche": bool(self.scanning)}

    # ---------------------------------------------------------------- Speicher
    def _scan_rx(self):
        last, n = 0, 0
        try:
            with open(self.rx_path) as f:
                for line in f:
                    n += 1
                    try:
                        last = max(last, json.loads(line)["id"])
                    except (ValueError, KeyError):
                        pass
        except OSError:
            pass
        return last, n

    def _load_json(self, name):
        try:
            with open(os.path.join(self.dir, name)) as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def _save_json(self, name, obj):
        tmp = os.path.join(self.dir, name + ".neu")
        with open(tmp, "w") as f:
            json.dump(obj, f, ensure_ascii=False)
        os.replace(tmp, os.path.join(self.dir, name))

    def _store(self, role, ev):
        with self.lock:
            self.last_id += 1
            item = {"id": self.last_id, "t": round(time.time(), 3), "role": role, "rssi": ev["rssi"],
                    "snr": ev["snr"], "fe": ev["freq_error"], "crc": ev["crc_error"], "d": ev["data"].hex()}
            with open(self.rx_path, "a") as f:
                f.write(json.dumps(item, separators=(",", ":")) + "\n")
            self.rx_lines += 1
            if self.rx_lines > RX_KEEP + 1000:
                self._trim_rx()
        self._push({"op": "cursor", "last": item["id"], "role": role})
        return item

    def _trim_rx(self):
        with open(self.rx_path) as f:
            lines = f.readlines()[-RX_KEEP:]
        tmp = self.rx_path + ".neu"
        with open(tmp, "w") as f:
            f.writelines(lines)
        os.replace(tmp, self.rx_path)
        self.rx_lines = len(lines)

    def sync(self, since, limit=150):
        items, more = [], False
        try:
            with open(self.rx_path) as f:
                for line in f:
                    try:
                        it = json.loads(line)
                    except ValueError:
                        continue
                    if it.get("id", 0) <= since:
                        continue
                    if len(items) >= limit:
                        more = True
                        break
                    items.append(it)
        except OSError:
            pass
        return {"items": items, "more": more, "last": items[-1]["id"] if items else since, "head": self.last_id}

    def update_settings(self, new):
        with self.lock:
            for k in SETTINGS_DEFAULT:
                if k in new:
                    if k in ("radio", "loud_dbm") and isinstance(new[k], dict):
                        # je Modul: Werte eines gerade nicht verbundenen Moduls behalten
                        merged = dict(self.settings.get(k) or {})
                        merged.update(new[k])
                        if k == "loud_dbm":
                            merged = {r: v for r, v in merged.items() if r in new[k]}
                        self.settings[k] = merged
                    else:
                        self.settings[k] = new[k]
            self.cfg.update(mailbox=self.settings)
        return dict(self.settings)

    # ---------------------------------------------------------------- Empfang
    def _rx_loop(self):
        while True:
            role, ev = self.rxq.get()
            try:
                self._store(role, ev)
                if not ev["crc_error"] and role == self.settings.get("lr_role"):
                    self._on_lr(role, ev)
            except Exception:
                log.exception("Postfach: Paket von %s", role)

    def _on_boot(self, role):
        """ESP32 neu gestartet: die zuletzt von der App gesetzten Funkwerte wieder einstellen."""
        c = (self.settings.get("radio") or {}).get(role)
        if not c:
            return
        time.sleep(1.5)
        try:
            apply_cfg(self.modems[role], c)
            log.info("ESP32 %s neu gestartet – Funkwerte wieder gesetzt (%.3f MHz)", role, c["freq_hz"] / 1e6)
        except Exception as e:
            log.warning("ESP32 %s: Funkwerte setzen fehlgeschlagen: %s", role, e)

    @property
    def me(self):
        return self.settings.get("num") or 0x4C520000

    @property
    def call(self):
        return (self.settings.get("callsign") or "").strip().upper()[:12]

    def _on_lr(self, role, ev):
        p = lr_parse(ev["data"])
        if p is None or p["from"] == self.me:
            return
        key = "%08x" % p["from"]
        dup = "%s:%d" % (key, p["id"])
        now = time.time()
        if dup in self.seen:
            return
        self.seen[dup] = now
        who = p["call"] or key
        t = p["type"]
        if t == LR_TEXT:
            if self.settings.get("auto_ack") and self.call:
                ack = lr_build(LR_ACK, self.me, random.getrandbits(32), self.call, self.settings.get("name", ""),
                               struct.pack("<I", p["id"]))
                self._respond(role, ack, 0.3 + random.random() * 1.2)
        elif t == LR_FILE:
            c = chunk_parse(p["body"])
            if c:
                self._on_chunk(role, key, who, c)
        elif t == LR_ANNOUNCE:
            a = announce_parse(p["body"])
            if a:
                self._on_announce(role, key, who, a)
        elif t == LR_FILE_ACK:
            a = ack_parse(p["body"])
            if a:
                self._on_file_ack(who, a)

    def _hold(self, role, seconds):
        with self.lock:
            self.quiet_until[role] = max(self.quiet_until[role], time.time() + min(seconds, 1800))

    def _in_for(self, role, key, who, xfer, count, size):
        xkey = "%s:%d" % (key, xfer)
        x = self.inx.get(xkey)
        if x is None:
            x = {"xkey": xkey, "role": role, "key": key, "who": who, "xfer": xfer, "count": count, "size": size,
                 "parts": {}, "name": "", "mime": "", "nacks": 0, "timer": None, "announced": False,
                 "started": time.time()}
            self.inx[xkey] = x
        return x

    def _timer(self, x, seconds, fn):
        if x.get("timer"):
            x["timer"].cancel()
        t = threading.Timer(seconds, fn)
        t.daemon = True
        x["timer"] = t
        t.start()

    def _on_announce(self, role, key, who, a):
        xkey = "%s:%d" % (key, a["xfer"])
        if xkey in self.done_x:
            return
        with self.lock:
            x = self._in_for(role, key, who, a["xfer"], a["count"], a["size"])
            if not x["name"]:
                x["name"], x["mime"] = a["name"], a["mime"]
            self._hold(role, a["air"] * 1.5 + 20)
            if not x["announced"]:
                x["announced"] = True
                log.info("%s kündigt eine Datei an: %s (%d B, %d Teile)", who, a["name"], a["size"], a["count"])
            if not x["parts"]:
                self._timer(x, a["air"] + 15, lambda: self._nack(xkey))

    def _on_chunk(self, role, key, who, c):
        xkey = "%s:%d" % (key, c["xfer"])
        if xkey in self.done_x:
            if c["idx"] == c["count"] - 1:
                self._respond(role, self._ack_pkt(c["xfer"], True, []))
            return
        with self.lock:
            x = self._in_for(role, key, who, c["xfer"], c["count"], c["size"])
            if c["idx"] == 0:
                x["name"], x["mime"] = c["name"] or "", c["mime"] or ""
            x["parts"][c["idx"]] = c["data"]
            x["nacks"] = 0
            self._hold(role, 15)
            if len(x["parts"]) >= x["count"]:
                if x.get("timer"):
                    x["timer"].cancel()
                self._finish_in(x)
                return
            last = c["idx"] == c["count"] - 1
            self._timer(x, (0.6 + random.random() * 0.9) if last else 4.0, lambda: self._nack(xkey))

    def _nack(self, xkey):
        with self.lock:
            x = self.inx.get(xkey)
            if x is None:
                return
            miss = [i for i in range(x["count"]) if i not in x["parts"]]
            if not miss or x["nacks"] >= 8:
                return
            x["nacks"] += 1
            self._respond(x["role"], self._ack_pkt(x["xfer"], False, miss))
            self._timer(x, 10 + random.random() * 6 + (10 if len(miss) > 30 else 0), lambda: self._nack(xkey))

    def _finish_in(self, x):
        data = b"".join(x["parts"][i] for i in range(x["count"]))
        self.inx.pop(x["xkey"], None)
        self.done_x[x["xkey"]] = time.time()
        name = "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in (x["name"] or "datei"))[:60]
        fn = "%s_%s_%s" % (time.strftime("%Y%m%d-%H%M%S"), x["who"].replace("/", "_")[:12], name)
        path = os.path.join(self.dir, "files", fn)
        try:
            with open(path, "wb") as f:
                f.write(data)
            with open(os.path.join(self.dir, "files.jsonl"), "a") as f:
                f.write(json.dumps({"t": time.time(), "from": x["key"], "who": x["who"], "name": x["name"],
                                    "mime": x["mime"], "size": len(data), "file": fn}) + "\n")
        except OSError as e:
            log.warning("Datei speichern: %s", e)
        log.info("Datei von %s vollständig: %s (%d B)", x["who"], x["name"], len(data))
        self._respond(x["role"], self._ack_pkt(x["xfer"], True, []))
        with self.lock:
            if not any(o["role"] == x["role"] for o in self.inx.values()):
                self.quiet_until[x["role"]] = min(self.quiet_until[x["role"]], time.time() + 5)
        self._push({"op": "file", "from": x["key"], "who": x["who"], "name": x["name"], "size": len(data)})

    def _ack_pkt(self, xfer, done, missing):
        return lr_build(LR_FILE_ACK, self.me, random.getrandbits(32), self.call, "", ack_build(xfer, done, missing))

    def _respond(self, role, pkt, delay=0.0):
        """Antwort im Protokoll (Bestätigung, fehlende Teile) – nur mit Rufzeichen."""
        if not self.call:
            return
        if delay:
            t = threading.Timer(delay, lambda: self.resp[role].put(pkt))
            t.daemon = True
            t.start()
        else:
            self.resp[role].put(pkt)

    def _on_file_ack(self, who, a):
        with self.lock:
            job = next((j for j in self.jobs if j.kind == "file" and j.params.get("xfer") == a["xfer"]), None)
            if job is None:
                return
            job.last_ack = time.time()
            if a["done"]:
                if who not in job.acked_by:
                    job.acked_by.append(who)
                job.missing_by.pop(who, None)
            elif a["missing"]:
                job.missing_by[who] = a["total"]
                job.pending.update(i for i in a["missing"] if i < len(job.chunks))
                if job.finished_at is not None and time.time() - job.finished_at < 120:
                    # meldet sich nach dem Ende noch mit Lücken: weitermachen
                    job.finished_at = None
                    job.state, job.resume = "wartet", True
                    job.policy.stall = 0
        self._push_job(job)

    # ---------------------------------------------------------------- Senden
    def _worker(self, role):
        while True:
            try:
                self._drain(role, block=0.2)
                job = self._next_job(role)
                if job:
                    if job.kind == "file":
                        self._run_file(job)
                    elif job.kind == "scan":
                        self._run_scan(job)
            except Exception:
                log.exception("Postfach: Auftrag auf %s", role)
                time.sleep(1)

    def _drain(self, role, block=0.0):
        """Ausstehende Protokoll-Antworten senden."""
        q = self.resp[role]
        try:
            pkt = q.get(timeout=block) if block else q.get_nowait()
        except queue.Empty:
            return
        while True:
            if role not in self.scanning:
                self._send(role, pkt)
            try:
                pkt = q.get_nowait()
            except queue.Empty:
                return

    def _next_job(self, role):
        with self.lock:
            if time.time() < self.quiet_until[role]:
                # fremde Übertragung angekündigt: eigene Aufträge warten (Suchläufe dürfen)
                return next((j for j in self.jobs if j.role == role and j.state == "wartet" and j.kind == "scan"
                             and not j.cancelled), None)
            return next((j for j in self.jobs if j.role == role and j.state == "wartet" and not j.cancelled), None)

    def _wait_clear(self, role, max_s=60):
        m, w = self.modems[role], self.watch[role]
        t0 = time.time()
        waited = False
        while time.time() - t0 < max_s:
            try:
                v = m.rssi()
            except Exception:
                return
            if not w.busy(v):
                return
            if not waited:
                waited = True
                log.info("Kanal belegt (%.0f dBm, Rauschen %.0f dBm) – warte", v, w.floor or 0)
            time.sleep(0.25 + random.random() * 0.5)

    def _send(self, role, pkt, careful=None, job=None):
        """Ein Paket senden; bei belegtem Kanal (CAD) später noch einmal. Gibt True bei Erfolg zurück."""
        m = self.modems[role]
        careful = self.settings.get("clear", True) if careful is None else careful
        for attempt in range(10):
            if job is not None and job.cancelled:
                return False
            if careful:
                self._wait_clear(role)
            try:
                ev = m.tx_wait(pkt, tx_id=m.next_txid(), lbt=careful, timeout=15)
            except Exception as e:
                log.warning("Senden auf %s: %s", role, e)
                time.sleep(1)
                continue
            st = ev.get("status", -12)
            if st == -10:                       # Kanal belegt (anderes LoRa-Signal)
                time.sleep(1 + random.random() * 2)
                continue
            return st == 0
        return False

    def add_file_job(self, role, data, name, mime, opts):
        job = Job("file", role, name=name, mime=mime, xfer=opts.get("xfer") or random.getrandbits(32),
                  twice=opts.get("twice", self.settings.get("twice", True)),
                  loud_dbm=opts.get("loud_dbm"), announce=opts.get("announce", True),
                  air_s=opts.get("air_s", 0))
        job.data = data
        job.chunks = chunk_split(data, mime, name, job.params["xfer"])
        with self.lock:
            self.jobs.append(job)
        self._persist(job)
        log.info("Auftrag %s: Datei %s (%d B, %d Teile) auf %s", job.id, name, len(data), len(job.chunks), role)
        self._push_job(job)
        return job

    def _persist(self, job):
        base = os.path.join(self.dir, "jobs", job.id)
        if job.finished_at is not None:
            for ext in (".json", ".bin"):
                try:
                    os.remove(base + ext)
                except OSError:
                    pass
            return
        try:
            with open(base + ".bin", "wb") as f:
                f.write(job.data)
            with open(base + ".json", "w") as f:
                json.dump({"id": job.id, "role": job.role, "params": job.params}, f)
        except OSError as e:
            log.warning("Auftrag speichern: %s", e)

    def _load_jobs(self):
        d = os.path.join(self.dir, "jobs")
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".json"):
                continue
            try:
                with open(os.path.join(d, fn)) as f:
                    meta = json.load(f)
                with open(os.path.join(d, fn[:-5] + ".bin"), "rb") as f:
                    data = f.read()
            except (OSError, ValueError):
                continue
            p = meta["params"]
            job = Job("file", meta["role"], **p)
            job.id = meta["id"]
            job.data = data
            job.chunks = chunk_split(data, p.get("mime", ""), p.get("name", ""), p["xfer"])
            job.info = "nach Neustart fortgesetzt"
            self.jobs.append(job)
            log.info("Auftrag %s (%s) nach Neustart wieder aufgenommen", job.id, p.get("name"))

    def _push_job(self, job, force=True):
        now = time.time()
        if not force and now - getattr(job, "_pushed", 0) < 0.5:
            return
        job._pushed = now
        self._push({"op": "job", "job": job.public()})

    def _set(self, job, state=None, info=None, progress=None):
        if state is not None:
            job.state = state
        if info is not None:
            job.info = info
        if progress is not None:
            job.progress = progress
        self._push_job(job, force=state is not None)

    def _run_file(self, job):
        role, m = job.role, self.modems[job.role]
        if not self.call:
            self._finish_job(job, "fehler", "kein Rufzeichen auf der Node eingetragen")
            return
        n = len(job.chunks)
        cfg0, loud = None, False
        try:
            cfg0 = m.config()
            want = job.params.get("loud_dbm")
            if want and want > cfg0["power_dbm"]:
                apply_cfg(m, cfg0, power=int(want))
                loud = True
                log.info("Auftrag %s: volle erlaubte Leistung %d dBm", job.id, want)
        except Exception as e:
            log.warning("Auftrag %s: Funkwerte lesen/setzen: %s", job.id, e)
        try:
            if not job.resume:
                if job.params.get("announce", True):
                    self._set(job, "kündigt an", "Ankündigung")
                    body = announce_build(job.params["xfer"], len(job.data), n, job.params.get("air_s", 0),
                                          job.params.get("mime", ""), job.params.get("name", ""))
                    for k in range(3):
                        self._send(role, lr_build(LR_ANNOUNCE, self.me, random.getrandbits(32), self.call, "", body),
                                   job=job)
                        time.sleep(0.7)
                order = send_order(n) if job.params.get("twice", True) else list(range(n))
                self._set(job, "sendet", "sende %d Teile" % n)
                self._send_chunks(job, order)
            job.resume = False
            while not job.cancelled:
                self._await_acks(job)
                if job.pending:
                    if not self._resend(job):
                        break
                    continue
                if job.acked_by and not job.missing_by:
                    break
                if job.probes >= 5:
                    break
                job.probes += 1
                self._set(job, "wartet auf Antwort", "frage nach (%d/5)" % job.probes)
                self._send_chunks(job, [n - 1])
        finally:
            if loud and cfg0:
                try:
                    apply_cfg(m, cfg0)
                except Exception as e:
                    log.warning("Auftrag %s: Leistung zurückstellen: %s", job.id, e)
        if job.cancelled:
            self._finish_job(job, "abgebrochen", "abgebrochen")
        elif job.acked_by:
            open_ = [w for w in job.missing_by if w not in job.acked_by]
            self._finish_job(job, "fertig", "vollständig bei %s" % ", ".join(job.acked_by) +
                             (", unvollständig bei %s" % ", ".join(open_) if open_ else ""))
        elif job.missing_by:
            self._finish_job(job, "unvollständig", "unvollständig bei %s" % ", ".join(job.missing_by))
        else:
            self._finish_job(job, "keine Antwort", "keine Bestätigung")

    def _send_chunks(self, job, idxs):
        role = job.role
        for k, i in enumerate(idxs):
            if job.cancelled:
                return
            self._drain(role)
            pkt = lr_build(LR_FILE, self.me, random.getrandbits(32), self.call, "", job.chunks[i])
            self._send(role, pkt, job=job)
            job.sent.add(i)
            if job.round == 0:
                job.progress = len(job.sent) / len(job.chunks)
            self._push_job(job, force=False)
            time.sleep(0.15)

    def _await_acks(self, job):
        """Auf Rückmeldungen warten; kurz sammeln, wenn welche kommen."""
        role = job.role
        end = time.time() + 8 + job.probes * 2
        first = None
        while time.time() < end and not job.cancelled:
            self._drain(role, block=0.2)
            with self.lock:
                if job.pending:
                    first = first or time.time()
                    if time.time() - first > 1.5:
                        return
                elif job.acked_by and not job.missing_by:
                    return

    def _resend(self, job):
        with self.lock:
            miss = sorted(job.pending)
            job.pending.clear()
            total = sum(job.missing_by.values()) or len(miss)
        if not miss:
            return True
        if not job.policy.next(total):
            return False
        job.round += 1
        job.probes = 0
        self._set(job, "sendet nach", "Runde %d: %d fehlende Teile" % (job.round, len(miss)))
        self._send_chunks(job, miss)
        return True

    def _finish_job(self, job, state, info):
        job.finished_at = time.time()
        if state == "fertig":
            job.progress = 1.0
        self._set(job, state, info)
        self._persist(job)
        log.info("Auftrag %s: %s – %s", job.id, state, info)

    def cancel(self, job_id):
        with self.lock:
            for j in self.jobs:
                if j.id == job_id and j.finished_at is None:
                    j.cancelled = True
                    if j.state == "wartet":
                        self._finish_job(j, "abgebrochen", "abgebrochen")
                    return True
        return False

    # ---------------------------------------------------------------- Frequenzsuche
    def add_scan_job(self, role, from_mhz, to_mhz, bw_khz=125, minutes=5, step_khz=None):
        if not (150 <= from_mhz < to_mhz <= 2500) or to_mhz - from_mhz > 40:
            raise ValueError("Bereich ungültig")
        job = Job("scan", role, from_mhz=float(from_mhz), to_mhz=float(to_mhz), bw_khz=float(bw_khz),
                  minutes=max(0.2, min(float(minutes), 120)), step_khz=float(step_khz or bw_khz))
        with self.lock:
            self.jobs.append(job)
        self._push_job(job)
        return job

    def _run_scan(self, job):
        role, m, p = job.role, self.modems[job.role], job.params
        bw, step = p["bw_khz"], p["step_khz"]
        freqs = []
        f = p["from_mhz"] + bw / 2000
        while f <= p["to_mhz"] - bw / 2000 + 1e-9:
            freqs.append(round(f, 4))
            f += step / 1000
        if not freqs:
            self._finish_job(job, "fehler", "Bereich zu schmal")
            return
        try:
            cfg0 = m.config()
        except Exception as e:
            self._finish_job(job, "fehler", "Modem antwortet nicht: %s" % e)
            return
        stats = {fq: [0, 0, -99.0] for fq in freqs}     # Messungen, belegt, stärkstes Signal über Rauschen
        floors = []
        self.scanning.add(role)
        t0, total = time.time(), p["minutes"] * 60
        sweeps = 0
        self._set(job, "sucht", "Suchlauf über %d Kanäle" % len(freqs), 0.0)
        try:
            while time.time() - t0 < total and not job.cancelled:
                vals = {}
                for fq in freqs:
                    if job.cancelled:
                        break
                    try:
                        m.set_lora(fq, bw, cfg0["sf"], int(cfg0["cr"][2:]), int(cfg0["sync"], 16), 0, cfg0["preamble"])
                        m.rx_start()
                        time.sleep(0.01)
                        vals[fq] = [m.rssi() for _ in range(4)]
                    except Exception as e:
                        log.warning("Suche %.3f MHz: %s", fq, e)
                if not vals:
                    break
                allv = sorted(v for vs in vals.values() for v in vs)
                floor = allv[int(len(allv) * 0.2)]
                floors.append(floor)
                for fq, vs in vals.items():
                    st = stats[fq]
                    for v in vs:
                        st[0] += 1
                        if v > floor + 8:
                            st[1] += 1
                        st[2] = max(st[2], v - floor)
                sweeps += 1
                self._set(job, progress=min(1.0, (time.time() - t0) / total),
                          info="Durchgang %d, Rauschen %.0f dBm" % (sweeps, floor))
        finally:
            self.scanning.discard(role)
            try:
                c = (self.settings.get("radio") or {}).get(role)
                if c:
                    apply_cfg(m, c)
                else:
                    apply_cfg(m, cfg0)
            except Exception as e:
                log.warning("Suche: Funkwerte zurückstellen: %s", e)
        chans = [{"mhz": fq, "busy": round(st[1] / st[0], 4) if st[0] else 1.0, "max_db": round(st[2], 1)}
                 for fq, st in sorted(stats.items())]
        res = {"t": time.time(), "role": role, "from_mhz": p["from_mhz"], "to_mhz": p["to_mhz"], "bw_khz": bw,
               "step_khz": step, "minutes": round((time.time() - t0) / 60, 1), "sweeps": sweeps,
               "floor_dbm": round(sorted(floors)[len(floors) // 2], 1) if floors else None,
               "channels": chans, "quiet": quiet_windows(chans, bw, step)}
        job.result = res
        self.scan_result = res
        try:
            self._save_json("scan.json", res)
        except OSError:
            pass
        self._push({"op": "scan", "result": res})
        self._finish_job(job, "fertig" if not job.cancelled else "abgebrochen",
                         "%d Durchgänge, ruhigste Frequenz %.4f MHz" % (sweeps, res["quiet"][0]["mhz"])
                         if res["quiet"] else "%d Durchgänge" % sweeps)

    # ---------------------------------------------------------------- Aufräumen
    def _housekeeping(self):
        while True:
            time.sleep(60)
            now = time.time()
            with self.lock:
                self.seen = {k: t for k, t in self.seen.items() if now - t < 1800}
                self.done_x = {k: t for k, t in self.done_x.items() if now - t < 3600}
                for k, x in list(self.inx.items()):
                    if now - x["started"] > 6 * 3600:
                        self.inx.pop(k, None)
                fin = [j for j in self.jobs if j.finished_at is not None]
                if len(fin) > 30:
                    old = sorted(fin, key=lambda j: j.finished_at)[:len(fin) - 30]
                    self.jobs = [j for j in self.jobs if j not in old]

    # ---------------------------------------------------------------- Steuerkanal
    def _push(self, obj):
        with self.lock:
            clients = list(self.clients)
        for c in clients:
            c.send(obj)

    def _serve_tcp(self, port):
        while True:
            try:
                srv = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
                srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                srv.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
                srv.bind(("::", port))
            except OSError:
                srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                srv.bind(("0.0.0.0", port))
            srv.listen(8)
            try:
                while True:
                    conn, addr = srv.accept()
                    conn.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
                    threading.Thread(target=self.serve, args=(conn, "TCP %s" % addr[0]), daemon=True).start()
            except OSError as e:
                log.warning("Steuerkanal: %s – neuer Versuch", e)
                time.sleep(5)

    def serve(self, conn, label):
        c = ControlConn(conn)
        with self.lock:
            self.clients.append(c)
        log.info("Postfach: App verbunden (%s)", label)
        buf = b""
        try:
            while True:
                d = conn.recv(65536)
                if not d:
                    break
                buf += d
                if len(buf) > MAX_LINE:
                    break
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        req = json.loads(line)
                    except ValueError:
                        c.send({"op": "error", "error": "kein JSON"})
                        continue
                    try:
                        resp = self.handle(req)
                    except Exception as e:
                        log.exception("Steuerbefehl %s", req.get("op"))
                        resp = {"error": str(e)}
                    resp.setdefault("op", req.get("op"))
                    if "rid" in req:
                        resp["rid"] = req["rid"]
                    c.send(resp)
        except OSError:
            pass
        finally:
            with self.lock:
                if c in self.clients:
                    self.clients.remove(c)
            c.close()
            log.info("Postfach: App getrennt (%s)", label)

    def handle(self, req):
        op = req.get("op")
        if op == "hello":
            return {"version": 1, "caps": ["sync", "lrfile", "scan"], "head": self.last_id, "node": self.node_id,
                    "settings": self.settings, "jobs": [j.public() for j in self.jobs],
                    "scan": self.scan_result, "status": self.status()}
        if op == "settings":
            return {"settings": self.update_settings(req.get("settings") or {})}
        if op == "sync":
            return self.sync(int(req.get("since", 0)), int(req.get("limit", 150)))
        if op == "send_file":
            data = base64.b64decode(req["data"])
            if not data or len(data) > 1024 * 1024:
                return {"error": "Datei leer oder größer als 1 MB"}
            role = req.get("role") or self.settings.get("lr_role") or "B"
            job = self.add_file_job(role, data, req.get("name", "datei"), req.get("mime", ""), req.get("opts") or {})
            return {"job": job.public()}
        if op == "jobs":
            return {"jobs": [j.public() for j in self.jobs]}
        if op == "cancel":
            return {"ok": self.cancel(req.get("id"))}
        if op == "scan":
            role = req.get("role") or self.settings.get("lr_role") or "B"
            job = self.add_scan_job(role, float(req["from_mhz"]), float(req["to_mhz"]), float(req.get("bw_khz", 125)),
                                    float(req.get("minutes", 5)), req.get("step_khz"))
            return {"job": job.public()}
        if op == "scan_result":
            return {"result": self.scan_result}
        if op == "ping":
            return {"t": time.time()}
        return {"error": "unbekannter Befehl %s" % op}


class ControlConn:
    def __init__(self, sock):
        self.sock = sock
        self.wlock = threading.Lock()
        self.dead = False

    def send(self, obj):
        if self.dead:
            return
        data = (json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
        with self.wlock:
            try:
                self.sock.sendall(data)
            except OSError:
                self.dead = True

    def close(self):
        self.dead = True
        try:
            self.sock.close()
        except OSError:
            pass
