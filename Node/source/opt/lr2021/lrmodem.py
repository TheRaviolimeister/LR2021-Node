#!/usr/bin/env python3
"""
lrmodem.py – Steuerung der LR2021-Modem-Firmware (ESP32) vom Orange Pi oder PC aus.

Als Programm:
    python3 lrmodem.py -p /dev/ttyS3 info
    python3 lrmodem.py -p /dev/ttyS3 lora --preset meshtastic-eu
    python3 lrmodem.py -p /dev/ttyS3 rx
    python3 lrmodem.py -p /dev/ttyS3 tx "Hallo Welt"
    python3 lrmodem.py -h                      (alle Befehle)

Als Bibliothek:
    from lrmodem import LrModem
    m = LrModem("/dev/ttyS3")
    print(m.info())
    m.on_rx = lambda pkt: print(pkt)
    m.rx_start()

Braucht nur Python 3 (unter Linux keine Zusatzpakete). Unter Windows wird pyserial verwendet.
"""
import argparse
import os
import queue
import struct
import sys
import threading
import time

# --------------------------------------------------------------------------
# Protokoll (muss zu firmware/lr2021_modem/protocol.h passen)
# --------------------------------------------------------------------------
PROTO_VERSION = 1
PROTO_MAGIC = 0x444D524C

CMD = dict(PING=0x01, GET_INFO=0x02, GET_CONFIG=0x03, SET_LORA=0x10, SET_FSK=0x11, SET_LIMITS=0x12,
           SAVE=0x13, FACTORY=0x14, SET_AUTORX=0x15, TX=0x20, RX_START=0x21, STANDBY=0x22, SLEEP=0x23,
           CAD=0x24, GET_RSSI=0x25, GET_STATS=0x30, RESET_STATS=0x31, RESET_RADIO=0x40, REBOOT=0x41)
EVT_BOOT, EVT_RX, EVT_TX_DONE, EVT_LOG, EVT_ERROR = 0xE0, 0xE1, 0xE2, 0xE4, 0xE5

STATUS = {0: "OK", -1: "unbekannter Befehl", -2: "falsche Länge", -3: "ungültiger Parameter",
          -4: "beschäftigt / Warteschlange voll", -5: "Senden in diesem Band nicht freigegeben",
          -6: "Sendeleistung über Grenzwert", -7: "Sendezeit-Limit (Duty Cycle) erreicht",
          -8: "Fehler vom Funkchip", -9: "falsche Modulationsart", -10: "Kanal belegt (LBT)",
          -11: "Funkchip nicht bereit", -12: "Zeitüberschreitung"}
RADIO_STATE = {0: "aus", 1: "standby", 2: "empfang", 3: "senden", 4: "schlaf"}
MODEM_NAME = {1: "LoRa", 2: "FSK"}
BAND_NAME = {1: "HF (868)", 2: "LF (433)"}

# struct-Formate (gepackt, Little-Endian)
FMT_LORA = "<IIBBBbHBB"            # freq bw sf cr sync power preamble flags implicit_len
FMT_FSK = "<IIIIbHB8sBBBB"         # freq br fdev rxbw power preamble sync_len sync crc flags shaping fixed_len
FMT_LIMITS = "<BbbH"
FMT_INFO = "<BBBBcBBBBIIhhHII"
FMT_STATS = "<9I"
FMT_RX_HDR = "<hhiBI"              # rssi*10 snr*10 freq_err flags zeit_ms

PRESETS = {
    # Meshtastic EU_868 (Standardkanal), nur zum Mithören/Testen – Pakete sind verschlüsselt
    "meshtastic-eu":   dict(freq=869.525, bw=250, sf=11, cr=5, sync=0x2B, preamble=16),
    "meshtastic-eu-mf": dict(freq=869.525, bw=250, sf=9, cr=5, sync=0x2B, preamble=16),
    "meshtastic-eu-ms": dict(freq=869.525, bw=250, sf=10, cr=5, sync=0x2B, preamble=16),
    "meshtastic-eu-sf": dict(freq=869.525, bw=250, sf=7, cr=5, sync=0x2B, preamble=16),
    "meshtastic-eu-ss": dict(freq=869.525, bw=250, sf=8, cr=5, sync=0x2B, preamble=16),
    # MeshCore EU/UK Narrow (Standard), zum Mithören
    "meshcore-eu":     dict(freq=869.618, bw=62.5, sf=8, cr=8, sync=0x12, preamble=8),
    # einfache Testprofile
    "test-433":        dict(freq=433.875, bw=125, sf=9, cr=5, sync=0x12, preamble=8),
    "test-868":        dict(freq=869.525, bw=125, sf=9, cr=5, sync=0x12, preamble=8),
}


def crc16(data: bytes, crc: int = 0xFFFF) -> int:
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def cobs_encode(data: bytes) -> bytes:
    out = bytearray(b"\x00")
    code_pos, code = 0, 1
    for b in data:
        if b == 0:
            out[code_pos] = code
            code_pos, code = len(out), 1
            out.append(0)
        else:
            out.append(b)
            code += 1
            if code == 0xFF:
                out[code_pos] = code
                code_pos, code = len(out), 1
                out.append(0)
    out[code_pos] = code
    return bytes(out)


def cobs_decode(data: bytes) -> bytes:
    out = bytearray()
    i = 0
    while i < len(data):
        code = data[i]
        if code == 0:
            raise ValueError("COBS: Null im Rahmen")
        i += 1
        end = i + code - 1
        if end > len(data):
            raise ValueError("COBS: Rahmen zu kurz")
        out += data[i:end]
        i = end
        if code != 0xFF and i < len(data):
            out.append(0)
    return bytes(out)


def build_frame(ftype: int, seq: int, payload: bytes = b"") -> bytes:
    raw = bytes([ftype, seq & 0xFF]) + payload
    raw += struct.pack("<H", crc16(raw))
    return cobs_encode(raw) + b"\x00"


def parse_frame(encoded: bytes):
    raw = cobs_decode(encoded)
    if len(raw) < 4:
        raise ValueError("Rahmen zu kurz")
    if struct.unpack("<H", raw[-2:])[0] != crc16(raw[:-2]):
        raise ValueError("CRC falsch")
    return raw[0], raw[1], raw[2:-2]


class ModemError(Exception):
    def __init__(self, status, radiolib=None):
        self.status = status
        self.radiolib = radiolib
        msg = STATUS.get(status, "Status %d" % status)
        if radiolib is not None:
            msg += " (RadioLib %d)" % radiolib
        super().__init__(msg)


# --------------------------------------------------------------------------
# Serielle Schnittstelle ohne Zusatzpakete (Linux) bzw. pyserial (Windows/macOS)
# --------------------------------------------------------------------------
class PosixSerial:
    def __init__(self, path, baud):
        import termios
        self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
        attrs = termios.tcgetattr(self.fd)
        speed = getattr(termios, "B%d" % baud)
        attrs[0] = 0                                        # iflag
        attrs[1] = 0                                        # oflag
        attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        attrs[3] = 0                                        # lflag
        attrs[4] = attrs[5] = speed
        attrs[6][termios.VMIN] = 0
        attrs[6][termios.VTIME] = 1                         # 0,1 s
        termios.tcsetattr(self.fd, termios.TCSANOW, attrs)
        termios.tcflush(self.fd, termios.TCIOFLUSH)

    def read(self, n):
        return os.read(self.fd, n)

    def write(self, data):
        view = memoryview(data)
        while view:
            k = os.write(self.fd, view)
            view = view[k:]

    def close(self):
        os.close(self.fd)


def open_port(path, baud):
    if os.name == "posix" and not path.startswith(("socket://", "rfc2217://")):
        try:
            return PosixSerial(path, baud)
        except (ImportError, AttributeError):
            pass
    import serial  # pyserial
    s = serial.serial_for_url(path, baudrate=baud, timeout=0.1, do_not_open=True)
    s.dtr = False          # kein Reset des ESP32 beim Öffnen
    s.rts = False
    s.open()
    return s


# --------------------------------------------------------------------------
class LrModem:
    """Verbindung zu einem ESP32 mit LR2021-Modem-Firmware."""

    def __init__(self, port, baud=500000, timeout=2.0):
        self.ser = open_port(port, baud) if isinstance(port, str) else port
        self.timeout = timeout
        self.on_rx = None          # Funktion(dict) für empfangene Pakete
        self.on_tx_done = None     # Funktion(dict)
        self.on_log = None         # Funktion(level, text)
        self.on_boot = None        # Funktion(info-dict)
        self.events = queue.Queue()
        self._seq = 0
        self._lock = threading.Lock()
        self._pending = {}
        self._running = True
        self._buf = bytearray()
        self.bad_frames = 0
        self._thr = threading.Thread(target=self._reader, daemon=True)
        self._thr.start()

    # ---- Empfang ----
    def _reader(self):
        while self._running:
            try:
                chunk = self.ser.read(512)
            except Exception:                      # z. B. Port wurde gerade geschlossen
                if not self._running:
                    break
                time.sleep(0.1)
                continue
            if not chunk:
                continue
            for b in chunk:
                if b != 0:
                    if len(self._buf) < 1024:
                        self._buf.append(b)
                    continue
                if not self._buf:
                    continue
                enc, self._buf = bytes(self._buf), bytearray()
                try:
                    ftype, seq, payload = parse_frame(enc)
                except ValueError:
                    self.bad_frames += 1
                    continue
                self._dispatch(ftype, seq, payload)

    def _dispatch(self, ftype, seq, payload):
        if 0x81 <= ftype <= 0xDF:
            with self._lock:
                slot = self._pending.get((ftype & 0x7F, seq))
            if slot is not None:
                slot.put(payload)
            return
        ev = self._decode_event(ftype, payload)
        if ev is None:
            return
        cb = {"rx": self.on_rx, "tx_done": self.on_tx_done, "boot": self.on_boot}.get(ev["type"])
        if ev["type"] == "log" and self.on_log:
            self.on_log(ev["level"], ev["text"])
        elif cb:
            cb(ev)
        self.events.put(ev)

    @staticmethod
    def _decode_event(ftype, p):
        if ftype == EVT_RX and len(p) >= 13:
            rssi, snr, fe, flags, t = struct.unpack(FMT_RX_HDR, p[:13])
            return dict(type="rx", rssi=rssi / 10, snr=snr / 10, freq_error=fe,
                        crc_error=bool(flags & 1), time_ms=t, data=bytes(p[13:]))
        if ftype == EVT_TX_DONE and len(p) >= 8:
            tid, st, toa = struct.unpack("<HhI", p[:8])
            return dict(type="tx_done", id=tid, status=st, status_text=STATUS.get(st, str(st)), airtime_us=toa)
        if ftype == EVT_LOG and len(p) >= 1:
            return dict(type="log", level=p[0], text=bytes(p[1:]).decode("utf-8", "replace"))
        if ftype == EVT_BOOT:
            d = LrModem._decode_info(p)
            d["type"] = "boot"
            return d
        if ftype == EVT_ERROR and len(p) >= 4:
            c, r = struct.unpack("<hh", p[:4])
            return dict(type="error", code=c, radiolib=r)
        return None

    @staticmethod
    def _decode_info(p):
        if len(p) < struct.calcsize(FMT_INFO):
            return {"raw": bytes(p)}
        f = struct.unpack(FMT_INFO, p[:struct.calcsize(FMT_INFO)])
        return dict(proto=f[0], firmware="%d.%d.%d" % f[1:4], role=f[4].decode(), band=BAND_NAME.get(f[5], f[5]),
                    radio_ok=bool(f[6]), radio_state=RADIO_STATE.get(f[7], f[7]), modem=MODEM_NAME.get(f[8], f[8]),
                    uptime_s=f[9] / 1000, chip_id="%08X" % f[10], init_code=f[11], temp_c=f[12] / 10,
                    vbat_v=f[13] / 1000, subghz_range_mhz=(f[14] / 1e6, f[15] / 1e6))

    # ---- Senden ----
    def request(self, cmd, payload=b"", timeout=None):
        with self._lock:
            self._seq = (self._seq + 1) & 0xFF
            seq = self._seq
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
        data = resp[2:]
        if status != 0:
            rl = struct.unpack("<h", data[:2])[0] if status == -8 and len(data) >= 2 else None
            raise ModemError(status, rl)
        return data

    def close(self):
        self._running = False
        try:
            self.ser.close()
        except Exception:
            pass

    # ---- Befehle ----
    def ping(self):
        d = self.request(CMD["PING"])
        magic, ver = struct.unpack("<IB", d[:5])
        if magic != PROTO_MAGIC:
            raise ModemError(-3)
        return ver

    def info(self):
        return self._decode_info(self.request(CMD["GET_INFO"]))

    def config(self):
        d = self.request(CMD["GET_CONFIG"])
        modem = d[0]
        out = dict(modem=MODEM_NAME.get(modem, modem))
        if modem == 2:
            n = struct.calcsize(FMT_FSK)
            f = struct.unpack(FMT_FSK, d[1:1 + n])
            out.update(freq_mhz=f[0] / 1e6, bitrate=f[1], fdev_hz=f[2], rxbw_hz=f[3], power_dbm=f[4],
                       preamble_bits=f[5], sync=f[7][:f[6]].hex(), crc_len=f[8], whitening=bool(f[9] & 1),
                       fixed_len=f[11] if f[9] & 2 else None, shaping=f[10])
        else:
            n = struct.calcsize(FMT_LORA)
            f = struct.unpack(FMT_LORA, d[1:1 + n])
            out.update(freq_mhz=f[0] / 1e6, bw_khz=f[1] / 1e3, sf=f[2], cr="4/%d" % f[3], sync="0x%02X" % f[4],
                       power_dbm=f[5], preamble=f[6], crc=bool(f[7] & 1), iq_inverted=bool(f[7] & 2),
                       implicit_len=f[8] if f[7] & 4 else None)
        lim = struct.unpack(FMT_LIMITS, d[1 + n:1 + n + struct.calcsize(FMT_LIMITS)])
        out["limits"] = dict(tx_subghz=bool(lim[0] & 1), tx_24ghz=bool(lim[0] & 2), max_power_subghz=lim[1],
                             max_power_24ghz=lim[2], duty_permille=lim[3])
        out["autorx"] = bool(d[-1])
        return out

    def set_lora(self, freq_mhz, bw_khz=125, sf=9, cr=5, sync=0x12, power=10, preamble=8,
                 crc=True, iq_inverted=False, implicit_len=0, ldro=None):
        flags = (1 if crc else 0) | (2 if iq_inverted else 0) | (4 if implicit_len else 0)
        if ldro is True:
            flags |= 8
        elif ldro is False:
            flags |= 16
        p = struct.pack(FMT_LORA, int(round(freq_mhz * 1e6)), int(round(bw_khz * 1000)), sf, cr, sync,
                        power, preamble, flags, implicit_len)
        self.request(CMD["SET_LORA"], p, timeout=5)

    def set_fsk(self, freq_mhz, bitrate=50000, fdev_hz=25000, rxbw_hz=136400, power=10, preamble_bits=32,
                sync=b"\x12\xAD", crc_len=2, whitening=True, shaping=2, fixed_len=0):
        flags = (1 if whitening else 0) | (2 if fixed_len else 0)
        p = struct.pack(FMT_FSK, int(round(freq_mhz * 1e6)), bitrate, fdev_hz, rxbw_hz, power, preamble_bits,
                        len(sync), bytes(sync).ljust(8, b"\x00"), crc_len, flags, shaping, fixed_len)
        self.request(CMD["SET_FSK"], p, timeout=5)

    def set_limits(self, tx_subghz=True, tx_24ghz=False, max_power_subghz=22, max_power_24ghz=12, duty_permille=0):
        mask = (1 if tx_subghz else 0) | (2 if tx_24ghz else 0)
        self.request(CMD["SET_LIMITS"], struct.pack(FMT_LIMITS, mask, max_power_subghz, max_power_24ghz, duty_permille))

    def save(self):
        self.request(CMD["SAVE"])

    def factory_reset(self):
        self.request(CMD["FACTORY"])

    def set_autorx(self, on):
        self.request(CMD["SET_AUTORX"], bytes([1 if on else 0]))

    def tx(self, data, tx_id=0, lbt=False):
        if isinstance(data, str):
            data = data.encode("utf-8")
        self.request(CMD["TX"], struct.pack("<BH", 1 if lbt else 0, tx_id & 0xFFFF) + bytes(data))

    def tx_wait(self, data, tx_id=None, lbt=False, timeout=30):
        """Sendet und wartet auf die Bestätigung. Gibt das tx_done-Ereignis zurück."""
        tx_id = (int(time.time() * 1000) & 0xFFFF) if tx_id is None else tx_id
        done = queue.Queue()
        old = self.on_tx_done

        def cb(ev):
            if ev["id"] == tx_id:
                done.put(ev)
            if old:
                old(ev)
        self.on_tx_done = cb
        try:
            self.tx(data, tx_id, lbt)
            return done.get(timeout=timeout)
        finally:
            self.on_tx_done = old

    def rx_start(self):
        self.request(CMD["RX_START"])

    def standby(self):
        self.request(CMD["STANDBY"])

    def sleep(self):
        self.request(CMD["SLEEP"])

    def cad(self):
        return bool(self.request(CMD["CAD"], timeout=3)[0])

    def rssi(self):
        return struct.unpack("<h", self.request(CMD["GET_RSSI"])[:2])[0] / 10

    def stats(self):
        names = ["rx_ok", "rx_crc_error", "tx_ok", "tx_fail", "tx_rejected", "airtime_total_ms",
                 "airtime_last_hour_ms", "link_bad_frames", "cad_busy"]
        return dict(zip(names, struct.unpack(FMT_STATS, self.request(CMD["GET_STATS"])[:36])))

    def reset_stats(self):
        self.request(CMD["RESET_STATS"])

    def reset_radio(self):
        self.request(CMD["RESET_RADIO"], timeout=5)

    def reboot(self):
        self.request(CMD["REBOOT"])


# --------------------------------------------------------------------------
# Kommandozeile
# --------------------------------------------------------------------------
def _print_dict(d, indent=""):
    for k, v in d.items():
        if isinstance(v, dict):
            print("%s%s:" % (indent, k))
            _print_dict(v, indent + "  ")
        else:
            print("%s%-22s %s" % (indent, k, v))


def _fmt_rx(ev):
    data = ev["data"]
    try:
        txt = data.decode("utf-8")
        shown = txt if txt.isprintable() else None
    except UnicodeDecodeError:
        shown = None
    body = repr(shown) if shown is not None else data.hex()
    return "%s RX %3d B  RSSI %6.1f dBm  SNR %5.1f dB  Δf %+6d Hz%s  %s" % (
        time.strftime("%H:%M:%S"), len(data), ev["rssi"], ev["snr"], ev["freq_error"],
        "  CRC-FEHLER" if ev["crc_error"] else "", body)


def main(argv=None):
    ap = argparse.ArgumentParser(description="LR2021-Modem steuern")
    ap.add_argument("-p", "--port", default=os.environ.get("LRMODEM_PORT", "/dev/ttyS3"),
                    help="Schnittstelle, z. B. /dev/ttyS3 (ESP32 A), /dev/ttyS4 (ESP32 B), /dev/ttyUSB0, COM5")
    ap.add_argument("-b", "--baud", type=int, default=None,
                    help="Baudrate (Standard 500000 am Pi-UART, 115200 an USB)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("ping", help="Verbindung prüfen")
    sub.add_parser("info", help="Firmware, Rolle, Funkchip-Zustand")
    sub.add_parser("config", help="aktuelle Funkeinstellungen")
    sub.add_parser("stats", help="Zähler")

    p = sub.add_parser("lora", help="LoRa einstellen")
    p.add_argument("--preset", choices=sorted(PRESETS))
    p.add_argument("--freq", type=float, help="MHz")
    p.add_argument("--bw", type=float, help="kHz (7.8 … 1000)")
    p.add_argument("--sf", type=int)
    p.add_argument("--cr", type=int, help="5…8 für 4/5…4/8")
    p.add_argument("--sync", type=lambda s: int(s, 0))
    p.add_argument("--power", type=int, help="dBm")
    p.add_argument("--preamble", type=int)
    p.add_argument("--no-crc", action="store_true")
    p.add_argument("--iq-inverted", action="store_true")

    p = sub.add_parser("fsk", help="FSK einstellen")
    p.add_argument("--freq", type=float, required=True, help="MHz")
    p.add_argument("--bitrate", type=int, default=50000)
    p.add_argument("--fdev", type=int, default=25000, help="Hz")
    p.add_argument("--rxbw", type=int, default=136400, help="Hz")
    p.add_argument("--power", type=int, default=10)
    p.add_argument("--sync", default="12AD", help="hex, bis 8 Byte")

    p = sub.add_parser("limits", help="Sendefreigaben und Grenzwerte")
    p.add_argument("--subghz", type=int, choices=[0, 1], default=1, help="Sub-GHz senden erlaubt")
    p.add_argument("--ghz24", type=int, choices=[0, 1], default=0, help="2,4 GHz senden erlaubt")
    p.add_argument("--max-subghz", type=int, default=22)
    p.add_argument("--max-24", type=int, default=12)
    p.add_argument("--duty", type=int, default=0, help="Promille Sendezeit pro Stunde (10 = 1 %%), 0 = aus")

    p = sub.add_parser("tx", help="Paket senden")
    p.add_argument("text", nargs="?", default=None)
    p.add_argument("--hex", help="Nutzdaten als Hex")
    p.add_argument("--lbt", action="store_true", help="vorher prüfen, ob der Kanal frei ist")
    p.add_argument("--repeat", type=int, default=1)
    p.add_argument("--interval", type=float, default=2.0, help="Sekunden zwischen Wiederholungen")

    sub.add_parser("rx", help="dauerhaft empfangen und Pakete anzeigen (Strg+C beendet)")
    sub.add_parser("monitor", help="nur Ereignisse anzeigen, nichts ändern")
    sub.add_parser("standby")
    sub.add_parser("sleep")
    sub.add_parser("cad", help="Kanal prüfen (LoRa)")
    sub.add_parser("rssi", help="aktuelle Feldstärke (im Empfang)")
    p = sub.add_parser("autorx", help="nach dem Start automatisch empfangen")
    p.add_argument("on", type=int, choices=[0, 1])
    sub.add_parser("save", help="aktuelle Einstellungen dauerhaft speichern")
    sub.add_parser("factory", help="gespeicherte Einstellungen löschen")
    sub.add_parser("reset-radio", help="LR2021 neu initialisieren")
    sub.add_parser("reboot", help="ESP32 neu starten")

    a = ap.parse_args(argv)
    baud = a.baud or (115200 if ("USB" in a.port or "ACM" in a.port or a.port.upper().startswith("COM")) else 500000)
    m = LrModem(a.port, baud)
    m.on_log = lambda lvl, txt: print("[%s] %s" % (("INFO", "WARN", "FEHLER")[min(lvl, 2)], txt))
    try:
        if a.cmd == "ping":
            print("Modem antwortet, Protokoll v%d" % m.ping())
        elif a.cmd == "info":
            _print_dict(m.info())
        elif a.cmd == "config":
            _print_dict(m.config())
        elif a.cmd == "stats":
            _print_dict(m.stats())
        elif a.cmd == "lora":
            cfg = dict(PRESETS.get(a.preset, {})) if a.preset else {}
            cur = m.config()
            if cur.get("modem") == "LoRa" and not a.preset:
                cfg = dict(freq=cur["freq_mhz"], bw=cur["bw_khz"], sf=cur["sf"], cr=int(cur["cr"][2:]),
                           sync=int(cur["sync"], 16), preamble=cur["preamble"], power=cur["power_dbm"])
            for k in ("freq", "bw", "sf", "cr", "sync", "power", "preamble"):
                v = getattr(a, k)
                if v is not None:
                    cfg[k] = v
            if "freq" not in cfg:
                ap.error("--freq oder --preset angeben")
            m.set_lora(cfg["freq"], cfg.get("bw", 125), cfg.get("sf", 9), cfg.get("cr", 5), cfg.get("sync", 0x12),
                       cfg.get("power", cur.get("power_dbm", 10)), cfg.get("preamble", 8),
                       crc=not a.no_crc, iq_inverted=a.iq_inverted)
            _print_dict(m.config())
        elif a.cmd == "fsk":
            m.set_fsk(a.freq, a.bitrate, a.fdev, a.rxbw, a.power, sync=bytes.fromhex(a.sync))
            _print_dict(m.config())
        elif a.cmd == "limits":
            m.set_limits(bool(a.subghz), bool(a.ghz24), a.max_subghz, a.max_24, a.duty)
            _print_dict(m.config()["limits"])
        elif a.cmd == "tx":
            data = bytes.fromhex(a.hex) if a.hex else (a.text or "Hallo von LR2021").encode()
            for i in range(a.repeat):
                ev = m.tx_wait(data, lbt=a.lbt)
                print("TX %d/%d: %s, Sendezeit %.1f ms" % (i + 1, a.repeat, ev["status_text"], ev["airtime_us"] / 1000))
                if i + 1 < a.repeat:
                    time.sleep(a.interval)
        elif a.cmd in ("rx", "monitor"):
            m.on_rx = lambda ev: print(_fmt_rx(ev), flush=True)
            m.on_tx_done = lambda ev: print("TX fertig: id %d, %s" % (ev["id"], ev["status_text"]), flush=True)
            m.on_boot = lambda ev: print("Modem neu gestartet:", ev.get("firmware"), ev.get("role"), flush=True)
            if a.cmd == "rx":
                m.rx_start()
                c = m.config()
                print("Empfange auf %.3f MHz (%s) … Strg+C beendet" % (c["freq_mhz"], c["modem"]))
            while True:
                time.sleep(1)
        elif a.cmd == "standby":
            m.standby()
        elif a.cmd == "sleep":
            m.sleep()
        elif a.cmd == "cad":
            print("Kanal belegt" if m.cad() else "Kanal frei")
        elif a.cmd == "rssi":
            print("%.1f dBm" % m.rssi())
        elif a.cmd == "autorx":
            m.set_autorx(bool(a.on))
            print("gesetzt – mit 'save' dauerhaft speichern")
        elif a.cmd == "save":
            m.save()
            print("gespeichert")
        elif a.cmd == "factory":
            m.factory_reset()
            print("gelöscht, Modem startet neu")
        elif a.cmd == "reset-radio":
            m.reset_radio()
            print("LR2021 neu initialisiert")
        elif a.cmd == "reboot":
            m.reboot()
            print("Modem startet neu")
    except KeyboardInterrupt:
        pass
    except (ModemError, TimeoutError) as e:
        print("Fehler:", e, file=sys.stderr)
        return 1
    finally:
        m.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
