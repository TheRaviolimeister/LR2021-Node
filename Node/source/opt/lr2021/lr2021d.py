#!/usr/bin/env python3
"""
lr2021d – der Dienst auf dem Orange Pi der LR2021 Node.

  * findet beide ESP32-Modems (USB oder UART) und erkennt per GET_INFO, welches A und welches B ist
  * stellt sie bereit: TCP 2021 (A, HF 868), 2022 (B, LF 433), GPS-NMEA auf 2023
  * dieselben Kanäle per Bluetooth (serielle Verbindung, RFCOMM-Kanal 1/2/3)
  * Web-Oberfläche auf Port 80: Status, WLAN, Passwort, Update der Node und der ESP32

Nur Python-Standardbibliothek. Alle Netzwege (WLAN-Hotspot, USB-Netz, LAN) erreichen denselben Dienst.
"""
import base64
import glob
import hashlib
import http.server
import io
import json
import logging
import os
import re
import shutil
import socket
import socketserver
import subprocess
import sys
import tarfile
import threading
import time
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from lrmodem import build_frame, parse_frame, open_port  # noqa: E402

VERSION = "1.0.2"
CONF_PATH = "/etc/lr2021/node.json"
STATE_DIR = "/var/lib/lr2021"
INSTALL_DIR = "/opt/lr2021"
BACKUP_DIR = "/opt/lr2021.alt"
CMD_GET_INFO = 0x02
HOTSPOT_CON = "LR2021-Hotspot"          # Anzeigename für „Hotspot aktiv“ (und alter NM-Profilname)
CLIENT_CON = "LR2021-WLAN"              # NetworkManager-Profil fürs Heim-WLAN
HOTSPOT_UNIT = "lr2021-hotspot.service"
HOTSPOT_CONF = "/run/lr2021/hotspot.conf"

DEFAULTS = {
    "node_name": "",                 # leer = Hostname
    "admin_password": "lr2021node",  # für Änderungen über die Web-Oberfläche
    "ap_ssid": "",                   # leer = LR2021-<Kennung>
    "ap_psk": "lr2021node",
    "ap_band": "bg",
    "ap_channel": 6,
    "wlan_client_ssid": "",          # bekanntes Heim-WLAN (Passwort liegt nur bei NetworkManager)
    "usb_ip": "192.168.7.1",
    "ports": [],                     # leer = Modems automatisch suchen
    "skip_ports": [],
    "uart_baud": 500000,             # ESP32 an UART3/4; 460800 kann der H618 nicht (wird 500000)
    "usb_baud": 115200,
    "gps_port": "/dev/ttyS5",        # L76X an UART5 (Pin 11/13); leer = suchen
    "gps_baud": 9600,
    "tcp_port_a": 2021,
    "tcp_port_b": 2022,
    "tcp_port_gps": 2023,
    "http_port": 80,
    "bluetooth": True,
    "bt_channels": {"A": 1, "B": 2, "GPS": 3},
}

log = logging.getLogger("lr2021d")


# ============================================================== Konfiguration
class Config:
    def __init__(self, path=CONF_PATH):
        self.path = path
        self.data = dict(DEFAULTS)
        self.lock = threading.Lock()
        try:
            with open(path) as f:
                self.data.update(json.load(f))
        except FileNotFoundError:
            pass
        except Exception as e:
            log.warning("Konfiguration %s nicht lesbar: %s", path, e)

    def __getitem__(self, k):
        return self.data.get(k, DEFAULTS.get(k))

    def update(self, **kw):
        with self.lock:
            self.data.update(kw)
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            tmp = self.path + ".neu"
            with open(tmp, "w") as f:
                json.dump(self.data, f, indent=2, ensure_ascii=False)
            os.replace(tmp, self.path)


def node_id():
    """Kurze, feste Kennung aus der Seriennummer des Chips (oder MAC).
    Bevorzugt die von lr2021-firstboot festgelegte Kennung, damit Hostname, WLAN und USB übereinstimmen."""
    try:
        s = open("/etc/lr2021/node-id").read().strip().upper()
        if re.fullmatch(r"[0-9A-F]{4}", s):
            return s
    except OSError:
        pass
    for p in ("/sys/firmware/devicetree/base/serial-number",):
        try:
            s = open(p).read().strip("\x00\n ")
            if s:
                return hashlib.sha1(s.encode()).hexdigest()[:4].upper()
        except OSError:
            pass
    for p in sorted(glob.glob("/sys/class/net/*/address")):
        if "/lo/" in p:
            continue
        try:
            mac = open(p).read().strip()
            if mac and mac != "00:00:00:00:00:00":
                return mac.replace(":", "")[-4:].upper()
        except OSError:
            pass
    return "0000"


def hotspot_ssid(cfg):
    return cfg["ap_ssid"] or "LR2021-%s" % node_id()


def hotspot_conf_text(cfg, ssid):
    """wpa_supplicant-Konfiguration für den Hotspot: nur WPA2-PSK (CCMP), ohne PMF.
    SSID und Schlüssel als Hex – damit sind Sonderzeichen im Namen/Passwort unkritisch."""
    ch = int(cfg["ap_channel"] or 6)
    if not 1 <= ch <= 13:
        ch = 6
    psk = hashlib.pbkdf2_hmac("sha1", cfg["ap_psk"].encode(), ssid.encode(), 4096, 32).hex()
    return ("# erzeugt von lr2021d – nicht von Hand ändern (Einstellungen: Weboberfläche bzw. /etc/lr2021/node.json)\n"
            "ctrl_interface=/run/lr2021/wpa\n"
            "ap_scan=1\n"
            "country=DE\n"
            "network={\n"
            "\tssid=%s\n"
            "\tmode=2\n"
            "\tfrequency=%d\n"
            "\tkey_mgmt=WPA-PSK\n"
            "\tieee80211w=0\n"
            "\tproto=RSN\n"
            "\tpairwise=CCMP\n"
            "\tgroup=CCMP\n"
            "\tpsk=%s\n"
            "}\n") % (ssid.encode().hex(), 2407 + 5 * ch, psk)


def write_hotspot_conf(cfg, path=HOTSPOT_CONF):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".neu"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(hotspot_conf_text(cfg, hotspot_ssid(cfg)))
    os.replace(tmp, path)


def sh(*cmd, timeout=20):
    """Befehl ausführen, (Rückgabe, Ausgabe) zurückgeben."""
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout, text=True)
        return r.returncode, r.stdout
    except FileNotFoundError:
        return 127, "%s nicht installiert" % cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "Zeitüberschreitung"


# ============================================================== Modems
def console_ports():
    out = set()
    try:
        for tok in open("/proc/cmdline").read().split():
            if tok.startswith("console="):
                out.add("/dev/" + tok.split("=", 1)[1].split(",")[0])
    except OSError:
        pass
    return out


def modem_candidates(cfg):
    if cfg["ports"]:
        return list(cfg["ports"])
    found = sorted(glob.glob("/dev/ttyACM*")) + sorted(glob.glob("/dev/ttyUSB*")) + sorted(glob.glob("/dev/ttyS*"))
    skip = set(cfg["skip_ports"]) | console_ports() | {cfg["gps_port"]}
    return [p for p in found if p not in skip and not p.startswith("/dev/ttyGS")]


def probe_modem(path, cfg):
    """Gibt (rolle, port, baud, info) zurück oder None."""
    usb = "ACM" in path or "USB" in path
    bauds = [cfg["usb_baud"], cfg["uart_baud"]] if usb else [cfg["uart_baud"], cfg["usb_baud"]]
    for baud in bauds:
        try:
            port = open_port(path, baud)
        except Exception:
            return None
        try:
            time.sleep(0.05)
            for attempt in range(4):
                port.write(build_frame(CMD_GET_INFO, 0x70 + attempt))
                buf, deadline = b"", time.time() + 0.7
                while time.time() < deadline:
                    chunk = port.read(256)
                    if not chunk:
                        continue
                    buf += chunk
                    while b"\x00" in buf:
                        raw, buf = buf.split(b"\x00", 1)
                        if not raw:
                            continue
                        try:
                            ftype, seq, payload = parse_frame(raw)
                        except Exception:
                            continue
                        if ftype == (CMD_GET_INFO | 0x80) and len(payload) >= 2 + 31:
                            i = payload[2:]
                            info = {
                                "fw": "%d.%d.%d" % (i[1], i[2], i[3]),
                                "role": chr(i[4]),
                                "band": "HF 868" if i[5] == 1 else "LF 433",
                                "radio_ok": bool(i[6]),
                                "chip_id": "%08X" % int.from_bytes(i[13:17], "little"),
                            }
                            return info["role"], port, baud, info
        except Exception as e:
            log.debug("%s @%d: %s", path, baud, e)
        try:
            port.close()
        except Exception:
            pass
    return None


class Fanout:
    """Gemeinsame Client-Verwaltung: Daten an alle verbundenen Clients."""

    def __init__(self, name):
        self.name = name
        self.clients = []
        self.lock = threading.Lock()

    def add_client(self, conn, label):
        with self.lock:
            self.clients.append(conn)
        log.info("%s: %s verbunden", self.name, label)

    def remove_client(self, conn, label=""):
        with self.lock:
            if conn in self.clients:
                self.clients.remove(conn)
        try:
            conn.close()
        except OSError:
            pass
        if label:
            log.info("%s: %s getrennt", self.name, label)

    def broadcast(self, data):
        with self.lock:
            clients = list(self.clients)
        for c in clients:
            try:
                c.sendall(data)
            except OSError:
                self.remove_client(c)

    @property
    def client_count(self):
        with self.lock:
            return len(self.clients)


class ModemLink(Fanout):
    def __init__(self, role):
        super().__init__("ESP32 " + role)
        self.role = role
        self.port = None
        self.path = None
        self.info = {}
        self.paused = False
        self.wlock = threading.Lock()
        self.rx_bytes = 0
        self.since = None

    def attach(self, port, path, info):
        self.port, self.path, self.info = port, path, info
        self.since = time.time()
        threading.Thread(target=self._reader, daemon=True).start()
        log.info("ESP32 %s an %s (Firmware %s)", self.role, path, info.get("fw"))

    def detach(self):
        port, self.port = self.port, None
        if port:
            try:
                port.close()
            except Exception:
                pass

    def _reader(self):
        port = self.port
        while self.port is port and port is not None:
            try:
                data = port.read(1024)
            except Exception as e:
                if self.port is port:
                    log.warning("ESP32 %s (%s) getrennt: %s", self.role, self.path, e)
                    self.port = None
                break
            if data:
                self.rx_bytes += len(data)
                self.broadcast(data)

    def write(self, data):
        port = self.port
        if port is None:
            return
        with self.wlock:
            try:
                port.write(data)
            except Exception as e:
                log.warning("Schreiben auf ESP32 %s: %s", self.role, e)


class GpsLink(Fanout):
    def __init__(self):
        super().__init__("GPS")
        self.port = None
        self.path = None
        self.fix = {}
        self.last_line = 0

    def attach(self, port, path):
        self.port, self.path = port, path
        threading.Thread(target=self._reader, daemon=True).start()
        log.info("GPS an %s", path)

    def _reader(self):
        port, buf = self.port, b""
        while self.port is port:
            try:
                chunk = port.read(512)
            except Exception as e:
                log.warning("GPS getrennt: %s", e)
                self.port = None
                break
            if not chunk:
                continue
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip()
                if line.startswith(b"$"):
                    self.last_line = time.time()
                    self._parse(line.decode("ascii", "replace"))
                    self.broadcast(line + b"\r\n")
            if len(buf) > 4096:
                buf = b""

    def _parse(self, line):
        f = line.split("*")[0].split(",")
        try:
            if f[0][3:] == "GGA" and len(f) > 9:
                q = int(f[6] or 0)
                self.fix["sats"] = int(f[7] or 0)
                self.fix["valid"] = q > 0
                if q > 0:
                    self.fix["lat"] = (float(f[2][:2]) + float(f[2][2:]) / 60) * (-1 if f[3] == "S" else 1)
                    self.fix["lon"] = (float(f[4][:3]) + float(f[4][3:]) / 60) * (-1 if f[5] == "W" else 1)
                    self.fix["alt"] = float(f[9] or 0)
                    self.fix["time"] = time.time()
        except (ValueError, IndexError):
            pass


def probe_gps(path, baud):
    try:
        port = open_port(path, baud)
    except Exception:
        return None
    buf, deadline = b"", time.time() + 2.5
    while time.time() < deadline:
        try:
            chunk = port.read(256)
        except Exception:
            break
        if chunk:
            buf += chunk
            if re.search(rb"\$G[PNLBA][A-Z]{3},[^\r\n]*\*[0-9A-F]{2}", buf):
                return port
    try:
        port.close()
    except Exception:
        pass
    return None


class Hub:
    def __init__(self, cfg):
        self.cfg = cfg
        self.links = {"A": ModemLink("A"), "B": ModemLink("B")}
        self.gps = GpsLink()
        self.lock = threading.Lock()
        self.flashing = {}

    def link_for(self, target):
        return self.gps if target == "GPS" else self.links[target]

    def busy_paths(self):
        s = {l.path for l in self.links.values() if l.port is not None}
        if self.gps.port is not None:
            s.add(self.gps.path)
        return s

    def scan_loop(self):
        gps_tries = 0
        while True:
            with self.lock:
                if any(l.port is None and not l.paused for l in self.links.values()):
                    busy = self.busy_paths() | {p for p in self.flashing.values()}
                    for path in modem_candidates(self.cfg):
                        if path in busy:
                            continue
                        r = probe_modem(path, self.cfg)
                        if r is None:
                            continue
                        role, port, _, info = r
                        link = self.links.get(role)
                        if link is None or link.port is not None or link.paused:
                            port.close()
                            continue
                        link.attach(port, path, info)
                        busy.add(path)
                if self.gps.port is None and (gps_tries < 20 or gps_tries % 20 == 0):
                    busy = self.busy_paths()
                    paths = [self.cfg["gps_port"]] if self.cfg["gps_port"] else []
                    paths += [p for p in sorted(glob.glob("/dev/ttyS*")) if p not in busy and p not in console_ports()]
                    for path in dict.fromkeys(paths):
                        if not os.path.exists(path) or path in busy:
                            continue
                        gp = probe_gps(path, self.cfg["gps_baud"])
                        if gp is not None:
                            self.gps.attach(gp, path)
                            break
                if self.gps.port is None:
                    gps_tries += 1
            time.sleep(5 if any(l.port is None for l in self.links.values()) else 3)

    # ---- ESP32 neu flashen
    def flash(self, role, image_path, logf):
        """Modem freigeben, esptool laufen lassen, Modem wieder suchen."""
        link = self.links[role]
        with self.lock:
            path = link.path if link.port is not None else None
            if not path:
                # ESP32 antwortet nicht (z. B. kaputte Firmware): genau ein freier USB-Port → den nehmen
                busy = self.busy_paths() | set(self.flashing.values())
                free = [p for p in sorted(glob.glob("/dev/ttyACM*")) + sorted(glob.glob("/dev/ttyUSB*"))
                        if p not in busy]
                if len(free) != 1:
                    return False, ("ESP32 %s ist nicht verbunden und kein eindeutiger freier USB-Port "
                                   "gefunden (%s)" % (role, ", ".join(free) or "keiner"))
                path = free[0]
            link.paused = True
            self.flashing[role] = path
            link.detach()
        time.sleep(0.5)
        try:
            esptool = shutil.which("esptool") or shutil.which("esptool.py")
            cmd = [esptool] if esptool else [sys.executable, "-m", "esptool"]
            cmd += ["--chip", "esp32s3", "--port", path, "--baud", "460800",
                    "--before", "default_reset", "--after", "hard_reset",
                    "write_flash", "-z", "0x0", image_path]
            logf.write("$ %s\n" % " ".join(cmd))
            logf.flush()
            r = subprocess.run(cmd, stdout=logf, stderr=subprocess.STDOUT, timeout=300)
            ok = r.returncode == 0
            return ok, "Flashen %s" % ("erfolgreich" if ok else "fehlgeschlagen (Code %d)" % r.returncode)
        except Exception as e:
            return False, "Flashen fehlgeschlagen: %s" % e
        finally:
            with self.lock:
                link.paused = False
                self.flashing.pop(role, None)


# ============================================================== Netz-Zugänge
def tcp_frontend(hub, target, port, bind="0.0.0.0"):
    try:
        srv = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        srv.bind(("::", port))
    except OSError:
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((bind, port))
    srv.listen(8)
    log.info("%s auf TCP %d", target, port)
    while True:
        conn, addr = srv.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        conn.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        threading.Thread(target=serve_client, args=(hub, target, conn, "TCP %s" % addr[0]), daemon=True).start()


def serve_client(hub, target, conn, label):
    link = hub.link_for(target)
    link.add_client(conn, label)
    try:
        while True:
            data = conn.recv(1024)
            if not data:
                break
            if target != "GPS":
                link.write(data)
    except OSError:
        pass
    finally:
        link.remove_client(conn, label)


def bt_frontend(hub, target, channel):
    if not hasattr(socket, "AF_BLUETOOTH"):
        log.warning("Bluetooth: Python ohne Bluetooth-Unterstützung")
        return
    while True:
        try:
            srv = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM, socket.BTPROTO_RFCOMM)
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            srv.bind((socket.BDADDR_ANY, channel))
            srv.listen(2)
            log.info("%s per Bluetooth auf RFCOMM-Kanal %d", target, channel)
            while True:
                conn, addr = srv.accept()
                threading.Thread(target=serve_client, args=(hub, target, conn, "Bluetooth %s" % addr[0]), daemon=True).start()
        except OSError as e:
            log.warning("Bluetooth-Kanal %d: %s – neuer Versuch in 30 s", channel, e)
            time.sleep(30)


class BtAgent:
    """Hält bluetoothctl als Pairing-Agent am Laufen: koppeln ohne PIN, Geräte vertrauen."""

    def __init__(self, name, channels):
        self.name = name
        self.channels = channels
        self.state = "aus"

    def run(self):
        while True:
            if not shutil.which("bluetoothctl"):
                self.state = "BlueZ fehlt"
                return
            rc, out = sh("bluetoothctl", "show", timeout=10)
            if "Controller" not in out:
                self.state = "kein Bluetooth-Adapter"
                time.sleep(30)
                continue
            self._register_sdp()
            try:
                p = subprocess.Popen(["bluetoothctl"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True, bufsize=1)
                for c in ("power on", "system-alias %s" % self.name, "agent NoInputNoOutput", "default-agent",
                          "discoverable-timeout 0", "discoverable on", "pairable-timeout 0", "pairable on"):
                    p.stdin.write(c + "\n")
                p.stdin.flush()
                self.state = "sichtbar als „%s“" % self.name
                for line in p.stdout:
                    line = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", line)
                    if "(yes/no)" in line:
                        p.stdin.write("yes\n")
                        p.stdin.flush()
                    m = re.search(r"Device ([0-9A-F:]{17}) (Paired|Bonded): yes", line)
                    if m:
                        p.stdin.write("trust %s\n" % m.group(1))
                        p.stdin.flush()
                        log.info("Bluetooth: %s gekoppelt", m.group(1))
            except Exception as e:
                log.warning("Bluetooth-Agent: %s", e)
            self.state = "neu starten …"
            time.sleep(10)

    def _register_sdp(self):
        if not shutil.which("sdptool"):
            return
        rc, out = sh("sdptool", "browse", "local", timeout=10)
        for name, ch in self.channels.items():
            if "Channel: %d" % ch in out:
                continue
            sh("sdptool", "add", "--channel=%d" % ch, "SP", timeout=10)


# ============================================================== Web-Oberfläche
def ip_addresses():
    rc, out = sh("ip", "-j", "-4", "addr", timeout=5)
    res = {}
    try:
        for itf in json.loads(out):
            addrs = [a["local"] for a in itf.get("addr_info", []) if a.get("family") == "inet"]
            if addrs and itf["ifname"] != "lo":
                res[itf["ifname"]] = addrs
    except Exception:
        pass
    return res


class Web(http.server.BaseHTTPRequestHandler):
    server_version = "LR2021/" + VERSION
    app = None  # wird gesetzt

    def log_message(self, fmt, *args):
        log.debug("http %s " + fmt, self.client_address[0], *args)

    # ---- Hilfen
    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _auth(self):
        h = self.headers.get("Authorization", "")
        if h.startswith("Basic "):
            try:
                user, _, pw = base64.b64decode(h[6:]).decode().partition(":")
                if pw == self.app.cfg["admin_password"]:
                    return True
            except Exception:
                pass
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="LR2021 Node"')
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    def _body(self, limit=64 * 1024 * 1024):
        n = int(self.headers.get("Content-Length", "0"))
        if n <= 0 or n > limit:
            raise ValueError("Datei fehlt oder ist zu groß")
        data = b""
        while len(data) < n:
            chunk = self.rfile.read(min(1 << 20, n - len(data)))
            if not chunk:
                break
            data += chunk
        return data

    # ---- GET
    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/status":
            return self._json(self.app.status())
        if path == "/api/log":
            if not self._auth():
                return
            rc, out = sh("journalctl", "-u", "lr2021d", "-n", "300", "--no-pager", "-o", "short-iso", timeout=10)
            body = out.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path in ("/", "/index.html"):
            path = "/index.html"
        f = os.path.join(HERE, "www", os.path.basename(path))
        if os.path.isfile(f):
            data = open(f, "rb").read()
            ctype = "text/html; charset=utf-8" if f.endswith(".html") else "application/octet-stream"
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self._json({"fehler": "nicht gefunden"}, 404)

    # ---- POST
    def do_POST(self):
        path = urlparse(self.path).path
        if not self._auth():
            return
        try:
            if path == "/api/wifi":
                d = json.loads(self._body(4096))
                return self._json(self.app.set_wifi(d.get("ssid", ""), d.get("psk", ""), d.get("channel")))
            if path == "/api/wlan":
                d = json.loads(self._body(4096))
                return self._json(self.app.set_client_wifi(d.get("ssid", ""), d.get("psk", "")))
            if path == "/api/password":
                d = json.loads(self._body(4096))
                pw = d.get("password", "")
                if len(pw) < 8:
                    return self._json({"ok": False, "meldung": "mindestens 8 Zeichen"}, 400)
                self.app.cfg.update(admin_password=pw)
                return self._json({"ok": True, "meldung": "Passwort geändert"})
            if path.startswith("/api/esp/"):
                role = path.rsplit("/", 1)[1].upper()
                if role not in ("A", "B"):
                    return self._json({"ok": False, "meldung": "ESP32 A oder B"}, 400)
                data = self._body(16 * 1024 * 1024)
                if len(data) < 1024 or data[0] != 0xE9:
                    return self._json({"ok": False, "meldung": "Keine ESP32-Firmware (.bin, Adresse 0x0)"}, 400)
                return self._json(self.app.flash_esp(role, data))
            if path == "/api/update":
                data = self._body()
                return self._json(self.app.apply_update(data))
            if path == "/api/reboot":
                self._json({"ok": True, "meldung": "Neustart …"})
                threading.Timer(1.0, lambda: sh("systemctl", "reboot")).start()
                return
            if path == "/api/restart":
                self._json({"ok": True, "meldung": "Dienst startet neu …"})
                threading.Timer(1.0, lambda: os._exit(3)).start()
                return
        except Exception as e:
            log.exception("API %s", path)
            return self._json({"ok": False, "meldung": str(e)}, 500)
        self._json({"fehler": "nicht gefunden"}, 404)


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    address_family = socket.AF_INET6

    def server_bind(self):
        try:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except OSError:
            pass
        # nicht HTTPServer.server_bind: das ruft getfqdn() und hängt ohne DNS (offline) mehrere Sekunden
        socketserver.TCPServer.server_bind(self)
        self.server_name = socket.gethostname()
        self.server_port = self.server_address[1]


# ============================================================== Update / Rollback
def install_update(data, install_dir=INSTALL_DIR, backup_dir=BACKUP_DIR):
    """
    Update-Paket einspielen (gemeinsam für /api/update und „lr2021-update DATEI“).
    Paket: .tar.gz mit Ordner „lr2021/“ (neue Software für /opt/lr2021),
    optional „debs/*.deb“ und „install.sh“. Die alte Software bleibt als /opt/lr2021.alt.
    Gibt eine Liste von Meldungen zurück, wirft ValueError bei kaputtem Paket.
    """
    os.makedirs(STATE_DIR, exist_ok=True)
    work = os.path.join(STATE_DIR, "update")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    try:
        t = tarfile.open(fileobj=io.BytesIO(data), mode="r:*")
    except tarfile.TarError as e:
        raise ValueError("Kein gültiges Update-Paket (.tar.gz): %s" % e)
    with t:
        for m in t.getmembers():
            name = m.name[2:] if m.name.startswith("./") else m.name
            if name.startswith("/") or ".." in name.split("/"):
                raise ValueError("Ungültiger Pfad im Paket: %s" % m.name)
            if m.issym() or m.islnk():
                if m.linkname.startswith("/") or ".." in m.linkname.split("/"):
                    raise ValueError("Ungültiger Link im Paket: %s" % m.name)
            if not (m.isfile() or m.isdir() or m.issym() or m.islnk()):
                raise ValueError("Ungültiger Eintrag im Paket: %s" % m.name)
        try:
            t.extractall(work, filter="data")
        except TypeError:            # Python ohne filter-Argument
            t.extractall(work)
    out = []
    new = os.path.join(work, "lr2021")
    has_sw = os.path.isdir(new)
    if has_sw and not os.path.isfile(os.path.join(new, "lr2021d.py")):
        raise ValueError("Paket unvollständig: lr2021/lr2021d.py fehlt")
    debs = sorted(glob.glob(os.path.join(work, "debs", "*.deb")))
    inst = os.path.join(work, "install.sh")
    if not (has_sw or debs or os.path.isfile(inst)):
        raise ValueError("Paket enthält weder lr2021/ noch debs/ noch install.sh")
    if debs:
        rc, o = sh("dpkg", "-i", *debs, timeout=900)
        out.append("dpkg: Code %d\n%s" % (rc, o[-2000:]))
    if has_sw:
        staging = install_dir + ".neu"
        shutil.rmtree(staging, ignore_errors=True)
        shutil.copytree(new, staging, symlinks=True)
        if os.path.isdir(install_dir):
            shutil.rmtree(backup_dir, ignore_errors=True)
            os.rename(install_dir, backup_dir)          # alte Version sichern (gleiches Dateisystem → atomar)
        os.rename(staging, install_dir)
        out.append("Software ersetzt (alte Version: %s)" % backup_dir)
    if os.path.isfile(inst):
        rc, o = sh("sh", inst, timeout=900)
        out.append("install.sh: Code %d\n%s" % (rc, o[-2000:]))
    shutil.rmtree(work, ignore_errors=True)
    return out


def rollback(install_dir=INSTALL_DIR, backup_dir=BACKUP_DIR):
    """Aktuelle und gesicherte Version tauschen."""
    if not os.path.isfile(os.path.join(backup_dir, "lr2021d.py")):
        raise ValueError("Keine gesicherte Version in %s" % backup_dir)
    tmp = install_dir + ".tausch"
    shutil.rmtree(tmp, ignore_errors=True)
    os.rename(install_dir, tmp)
    os.rename(backup_dir, install_dir)
    os.rename(tmp, backup_dir)
    return ["Version getauscht: %s ↔ %s" % (install_dir, backup_dir)]


def cli_update(path=None, do_rollback=False):
    """Kommandozeile: lr2021d.py --update DATEI | --rollback (für lr2021-update per SSH/SCP)."""
    if os.geteuid() != 0:
        print("Bitte als root ausführen: sudo lr2021-update …", file=sys.stderr)
        return 1
    try:
        if do_rollback:
            out = rollback()
        else:
            with open(path, "rb") as f:
                out = install_update(f.read())
    except (OSError, ValueError) as e:
        print("FEHLER:", e, file=sys.stderr)
        return 2
    print("\n".join(out))
    rc, o = sh("systemctl", "restart", "lr2021d", timeout=60)
    print("Dienst lr2021d neu gestartet" if rc == 0 else "Dienst-Neustart: %s" % o.strip())
    return 0


# ============================================================== Anwendung
class App:
    def __init__(self, cfg):
        self.cfg = cfg
        self.hub = Hub(cfg)
        self.started = time.time()
        self.nid = node_id()
        self.bt = BtAgent(self.name, cfg["bt_channels"])
        self.last_action = ""

    @property
    def name(self):
        return self.cfg["node_name"] or "LR2021-%s" % self.nid

    @property
    def ssid(self):
        return hotspot_ssid(self.cfg)

    def status(self):
        h = self.hub
        modems = {}
        for r, l in h.links.items():
            modems[r] = {
                "verbunden": l.port is not None,
                "anschluss": l.path,
                "firmware": l.info.get("fw"),
                "band": l.info.get("band", "HF 868" if r == "A" else "LF 433"),
                "funkchip_ok": l.info.get("radio_ok"),
                "chip_id": l.info.get("chip_id"),
                "clients": l.client_count,
                "tcp": self.cfg["tcp_port_a" if r == "A" else "tcp_port_b"],
                "bluetooth_kanal": self.cfg["bt_channels"].get(r),
                "wird_geflasht": r in h.flashing,
            }
        rc, up = sh("cat", "/proc/uptime", timeout=2)
        temp = None
        for z in glob.glob("/sys/class/thermal/thermal_zone*/temp"):
            try:
                temp = max(temp or 0, int(open(z).read()) / 1000)
            except (OSError, ValueError):
                pass
        return {
            "name": self.name,
            "kennung": self.nid,
            "version": VERSION,
            "laufzeit_s": int(float(up.split()[0])) if rc == 0 else None,
            "dienst_laufzeit_s": int(time.time() - self.started),
            "temperatur_c": temp,
            "modems": modems,
            "gps": {"anschluss": h.gps.path, "verbunden": h.gps.port is not None, "clients": h.gps.client_count,
                    "daten": time.time() - h.gps.last_line < 5 if h.gps.last_line else False, **h.gps.fix},
            "wlan": {"ssid": self.ssid, "adresse": "10.42.0.1", "kanal": self.cfg["ap_channel"],
                     "aktiv": self.wlan_active() if shutil.which("nmcli") else None,
                     "heim_wlan": self.cfg["wlan_client_ssid"]},
            "usb": {"adresse": self.cfg["usb_ip"]},
            "bluetooth": self.bt.state,
            "adressen": ip_addresses(),
            "letzte_aktion": self.last_action,
        }

    # ---- WLAN
    # Der Hotspot läuft NICHT über NetworkManager: NM bietet im AP-Modus immer zusätzlich WPA-PSK-SHA256 an,
    # der UWE5622-Treiber kann aber kein PMF – Handys wählen SHA256 und scheitern („falsches Passwort“).
    # Stattdessen: Dienst lr2021-hotspot (wpa_supplicant-AP nur WPA-PSK + dnsmasq). wlan0 ist für NM per
    # udev „unmanaged“; nur für ein eingetragenes Heim-WLAN schaltet lr2021d wlan0 an NM zurück.
    @staticmethod
    def hotspot_running():
        return sh("systemctl", "is-active", "--quiet", HOTSPOT_UNIT, timeout=10)[0] == 0

    @classmethod
    def wlan_active(cls):
        """HOTSPOT_CON, wenn der Hotspot läuft; sonst die NM-Verbindung auf wlan0 (oder '')."""
        if cls.hotspot_running():
            return HOTSPOT_CON
        rc, out = sh("nmcli", "-t", "-f", "DEVICE,CONNECTION", "device", timeout=10)
        for line in out.splitlines():
            dev, _, con = line.partition(":")
            if dev == "wlan0":
                return con if con and con != "--" else ""
        return ""

    def apply_hotspot(self, force=False):
        """Hotspot-Konfiguration neu schreiben und den Hotspot (neu) starten, wenn nötig:
        force, geänderte Werte bei laufendem Hotspot, oder WLAN gerade ungenutzt.
        Ist die Node im Heim-WLAN, bleibt sie dort (außer force)."""
        new = hotspot_conf_text(self.cfg, self.ssid)
        try:
            old = open(HOTSPOT_CONF).read()
        except OSError:
            old = None
        active = self.wlan_active()
        if active not in ("", HOTSPOT_CON) and not force:
            log.info("Hotspot %s eingerichtet – Node ist im WLAN „%s“", self.ssid, active)
            return True, "Hotspot „%s“ eingerichtet (Node ist gerade im Heim-WLAN)" % self.ssid
        if not (force or active == "" or new != old):
            log.info("Hotspot %s läuft", self.ssid)
            return True, "Hotspot „%s“ aktiv" % self.ssid
        if active not in ("", HOTSPOT_CON):
            sh("nmcli", "device", "disconnect", "wlan0", timeout=20)
        sh("nmcli", "device", "set", "wlan0", "managed", "no", timeout=10)
        rc, out = sh("systemctl", "restart", HOTSPOT_UNIT, timeout=40)
        ok = False
        for _ in range(15):
            time.sleep(1)
            if self.hotspot_running():
                ok = True
                break
        log.info("Hotspot %s: %s", self.ssid, "aktiv" if ok else "startet nicht: " + out.strip())
        return ok, "Hotspot „%s“ %s" % (self.ssid, "aktiv" if ok else "konnte nicht starten – siehe Protokoll")

    def connect_client(self):
        """Ins eingetragene Heim-WLAN wechseln; klappt es nicht, zurück zum Hotspot."""
        ssid = self.cfg["wlan_client_ssid"]
        sh("systemctl", "stop", HOTSPOT_UNIT, timeout=30)
        sh("nmcli", "device", "set", "wlan0", "managed", "yes", timeout=10)
        time.sleep(4)
        rc, out = sh("nmcli", "connection", "up", CLIENT_CON, "ifname", "wlan0", timeout=70)
        if rc == 0:
            log.info("Heim-WLAN %s verbunden", ssid)
            self.last_action = "Heim-WLAN „%s“ verbunden" % ssid
            return True
        log.warning("Heim-WLAN %s: %s – zurück zum Hotspot", ssid, out.strip())
        self.last_action = "Heim-WLAN „%s“ nicht erreichbar – Hotspot aktiv" % ssid
        self.apply_hotspot(force=True)
        return False

    def wlan_watchdog(self):
        """Fällt das Heim-WLAN länger aus (ca. 2 min), wieder den Hotspot aufmachen."""
        misses = 0
        while True:
            time.sleep(30)
            if not self.cfg["wlan_client_ssid"] or self.hotspot_running():
                misses = 0
                continue
            misses = misses + 1 if self.wlan_active() != CLIENT_CON else 0
            if misses >= 4:
                log.warning("Heim-WLAN seit 2 min weg – Hotspot startet")
                self.last_action = "Heim-WLAN weg – Hotspot aktiv"
                self.apply_hotspot(force=True)
                misses = 0

    def start_wlan(self):
        """Beim Start: veralteten NetworkManager-Hotspot entfernen, dann Heim-WLAN oder Hotspot."""
        rc, out = sh("nmcli", "-t", "-f", "NAME", "connection", "show", timeout=10)
        if HOTSPOT_CON in out.splitlines():
            log.info("Alten NetworkManager-Hotspot entfernen")
            sh("nmcli", "connection", "delete", HOTSPOT_CON, timeout=20)
        if self.cfg["wlan_client_ssid"] and CLIENT_CON in out.splitlines():
            if self.wlan_active() != CLIENT_CON:
                self.connect_client()
        else:
            self.apply_hotspot()

    def set_client_wifi(self, ssid, psk):
        """Heim-WLAN eintragen (Vorrang vor dem Hotspot) oder mit leerem Namen entfernen."""
        if not shutil.which("nmcli"):
            return {"ok": False, "meldung": "NetworkManager fehlt"}
        ssid = ssid.strip()
        if not ssid:
            sh("nmcli", "connection", "delete", CLIENT_CON)
            self.cfg.update(wlan_client_ssid="")
            threading.Thread(target=self.apply_hotspot, kwargs={"force": True}, daemon=True).start()
            return {"ok": True, "meldung": "Heim-WLAN entfernt – Hotspot startet."}
        if not (1 <= len(ssid.encode()) <= 32):
            return {"ok": False, "meldung": "WLAN-Name: 1 bis 32 Zeichen"}
        if psk and not (8 <= len(psk) <= 63):
            return {"ok": False, "meldung": "WLAN-Passwort: 8 bis 63 Zeichen"}
        sh("nmcli", "connection", "delete", CLIENT_CON)
        args = ["nmcli", "connection", "add", "type", "wifi", "ifname", "wlan0", "con-name", CLIENT_CON,
                "ssid", ssid, "autoconnect", "yes", "connection.autoconnect-priority", "50",
                "ipv4.method", "auto", "ipv6.method", "auto"]
        if psk:
            args += ["wifi-sec.key-mgmt", "wpa-psk", "wifi-sec.psk", psk,
                     "wifi-sec.pmf", "1"]       # PMF aus (UWE5622-Treiber, siehe Hotspot)
        rc, out = sh(*args)
        if rc != 0:
            return {"ok": False, "meldung": "Heim-WLAN anlegen: " + out.strip()}
        self.cfg.update(wlan_client_ssid=ssid)
        threading.Thread(target=self.connect_client, daemon=True).start()
        return {"ok": True, "meldung": "Gespeichert. Die Node wechselt jetzt ins Heim-WLAN „%s“ – der Hotspot "
                                      "geht aus. Klappt die Verbindung nicht, kommt der Hotspot nach ca. 1 min "
                                      "zurück. Über USB bleibt die Node immer erreichbar." % ssid}

    def set_wifi(self, ssid, psk, channel=None):
        ssid = ssid.strip()
        if ssid and not (1 <= len(ssid.encode()) <= 32):
            return {"ok": False, "meldung": "WLAN-Name: 1 bis 32 Zeichen"}
        if psk and not (8 <= len(psk) <= 63):
            return {"ok": False, "meldung": "WLAN-Passwort: 8 bis 63 Zeichen"}
        kw = {}
        if ssid:
            kw["ap_ssid"] = ssid
        if psk:
            kw["ap_psk"] = psk
        if channel:
            kw["ap_channel"] = int(channel)
        self.cfg.update(**kw)
        threading.Thread(target=self.apply_hotspot, daemon=True).start()
        return {"ok": True, "meldung": "Gespeichert – der Hotspot startet mit den neuen Werten neu. Danach neu verbinden."}

    # ---- ESP32 flashen
    def flash_esp(self, role, data):
        os.makedirs(STATE_DIR, exist_ok=True)
        img = os.path.join(STATE_DIR, "esp_%s.bin" % role)
        with open(img, "wb") as f:
            f.write(data)
        logp = os.path.join(STATE_DIR, "esp_%s_flash.log" % role)
        with open(logp, "w") as logf:
            ok, msg = self.hub.flash(role, img, logf)
        tail = open(logp).read()[-3000:]
        self.last_action = "ESP32 %s: %s" % (role, msg)
        log.info(self.last_action)
        return {"ok": ok, "meldung": msg, "ausgabe": tail}

    # ---- Update der Node-Software
    def apply_update(self, data):
        out = install_update(data)
        self.last_action = "Update eingespielt"
        log.info("Update eingespielt: %s", "; ".join(x.split("\n")[0] for x in out))
        threading.Timer(2.0, lambda: os._exit(3)).start()   # systemd startet neu
        return {"ok": True, "meldung": "Update eingespielt, Dienst startet neu", "ausgabe": "\n".join(out)}

    # ---- Start
    def run(self):
        threading.Thread(target=self.hub.scan_loop, daemon=True).start()
        for target, key in (("A", "tcp_port_a"), ("B", "tcp_port_b"), ("GPS", "tcp_port_gps")):
            threading.Thread(target=tcp_frontend, args=(self.hub, target, self.cfg[key]), daemon=True).start()
        if self.cfg["bluetooth"]:
            threading.Thread(target=self.bt.run, daemon=True).start()
            for target, ch in self.cfg["bt_channels"].items():
                threading.Thread(target=bt_frontend, args=(self.hub, target, int(ch)), daemon=True).start()
        if shutil.which("nmcli"):
            threading.Thread(target=self.start_wlan, daemon=True).start()
            threading.Thread(target=self.wlan_watchdog, daemon=True).start()
        else:
            log.warning("NetworkManager fehlt – WLAN-Verwaltung aus")
        Web.app = self
        try:
            httpd = ThreadingHTTPServer(("::", self.cfg["http_port"]), Web)
        except OSError:
            ThreadingHTTPServer.address_family = socket.AF_INET
            httpd = ThreadingHTTPServer(("0.0.0.0", self.cfg["http_port"]), Web)
        log.info("LR2021 Node %s (%s) bereit – Web-Oberfläche auf Port %d", VERSION, self.name, self.cfg["http_port"])
        httpd.serve_forever()


def main():
    import argparse
    ap = argparse.ArgumentParser(description="LR2021 Node-Dienst")
    ap.add_argument("-c", "--config", default=CONF_PATH)
    ap.add_argument("-v", "--verbose", action="store_true")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--update", metavar="DATEI", help="Update-Paket (.tar.gz) einspielen und Dienst neu starten")
    g.add_argument("--rollback", action="store_true", help="zur gesicherten Version (/opt/lr2021.alt) zurück")
    g.add_argument("--hotspot-conf", metavar="DATEI", help="wpa_supplicant-Konfiguration für den Hotspot schreiben "
                                                         "(benutzt lr2021-hotspot.service)")
    a = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if a.verbose else logging.INFO, format="%(levelname)s %(message)s")
    if a.update or a.rollback:
        sys.exit(cli_update(a.update, a.rollback))
    if a.hotspot_conf:
        cfg = Config(a.config)
        write_hotspot_conf(cfg, a.hotspot_conf)
        print("Hotspot-Konfiguration %s geschrieben (SSID %s)" % (a.hotspot_conf, hotspot_ssid(cfg)))
        sys.exit(0)
    App(Config(a.config)).run()


if __name__ == "__main__":
    main()
