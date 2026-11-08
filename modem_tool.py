"""
LR2021-Modem Werkzeug für Windows (läuft mit dem Python von PlatformIO).
  modem_tool.py flash A   -> flasht lr2021_modem_A.bin auf den angeschlossenen ESP32
  modem_tool.py flash B   -> dasselbe für B
  modem_tool.py info      -> fragt das Modem ab
Alles wird zusätzlich in log.txt geschrieben.
"""
import os, sys, time, subprocess, datetime

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(HERE, "log.txt")
sys.path.insert(0, os.path.join(HERE, "host"))
sys.path.insert(0, os.path.join(HERE, "lib"))          # mitgeliefertes pyserial


def find_esptool():
    base = os.path.expanduser(r"~\AppData\Local\Arduino15\packages\esp32\tools\esptool_py")
    vers = sorted(os.listdir(base), key=lambda v: [int(x) if x.isdigit() else 0 for x in v.replace("-", ".").split(".")])
    for v in reversed(vers):
        exe = os.path.join(base, v, "esptool.exe")
        if os.path.exists(exe):
            return exe, int(v.split(".")[0])
    return None, 0


DEBUG_LOG = os.path.join(HERE, "debug_log.txt")
MESH_NAME_LANG = "LR2021 Prototyp"      # so erscheint die Node in den Meshtastic-Apps
MESH_NAME_KURZ = "LR21"                 # max. 4 Zeichen
MESH_LBT = False                        # vor dem Senden Kanal prüfen (CAD)


import threading as _th
_LOGLOCK = _th.RLock()


def dbg(*a):
    """Nur ins Debug-Log (mit Zeitstempel in ms), nicht auf den Bildschirm."""
    t = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    with _LOGLOCK:
        with open(DEBUG_LOG, "a", encoding="utf-8") as f:
            f.write(t + "  " + " ".join(str(x) for x in a) + "\n")


def _install_crash_logging():
    import traceback, threading

    def hook(exc_type, exc, tb):
        txt = "".join(traceback.format_exception(exc_type, exc, tb))
        dbg("ABSTURZ:\n" + txt)
        log("ABSTURZ: %s: %s (Details in debug_log.txt)" % (exc_type.__name__, exc))
    sys.excepthook = hook
    threading.excepthook = lambda a: hook(a.exc_type, a.exc_value, a.exc_traceback)


def log(*a):
    s = " ".join(str(x) for x in a)
    with _LOGLOCK:
        try:
            print(s, flush=True)
        except UnicodeEncodeError:
            print(s.encode("ascii", "replace").decode(), flush=True)
    try:
        dbg("LOG", s)
    except Exception:
        pass
    with _LOGLOCK:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(s + "\n")


def find_port():
    from serial.tools import list_ports
    ports = list(list_ports.comports())
    for p in ports:
        log("  gefunden: %s  %s  VID:PID=%s:%s" % (p.device, p.description,
            ("%04X" % p.vid) if p.vid else "-", ("%04X" % p.pid) if p.pid else "-"))
    # USB-Seriell-Chips typischer ESP32-S3-Boards: WCH (CH340/CH343), Silabs (CP210x), Espressif (nativ)
    good = [p for p in ports if p.vid in (0x1A86, 0x10C4, 0x303A)]
    if not good:
        return None
    # "COM"-Buchse (WCH/Silabs) bevorzugen
    good.sort(key=lambda p: 0 if p.vid in (0x1A86, 0x10C4) else 1)
    # Mehrere Kandidaten (z. B. zusätzlich der CP2102 der Pi-Debug-Konsole, auch Silabs):
    # nachfragen statt raten – sonst flasht esptool womöglich den falschen Port an.
    port_env = os.environ.get("LR2021_PORT")
    if port_env:
        return port_env
    if len(good) > 1 and sys.stdin and sys.stdin.isatty():
        log("Mehrere passende COM-Ports gefunden:")
        for i, p in enumerate(good, 1):
            log("  %d) %s  %s" % (i, p.device, p.description))
        log("Tipp: Den Port, der beim Einstecken des ESP32 neu erscheint, nehmen. Die Pi-Debug-Konsole")
        log("      (CP2102) ist es NICHT – die kann man vorher auch einfach abziehen.")
        while True:
            a = input("Nummer des ESP32-Ports (Enter = 1, q = Abbruch): ").strip().lower()
            if a == "q":
                return None
            if a == "":
                return good[0].device
            if a.isdigit() and 1 <= int(a) <= len(good):
                return good[int(a) - 1].device
    return good[0].device


def flash(role, diag=False):
    binf = os.path.join(HERE, "bin", "lr2021_modem_%s%s.bin" % (role, "_diag" if diag else ""))
    port = find_port()
    if not port:
        log("FEHLER: kein ESP32 gefunden. USB-Kabel an die Buchse 'COM' stecken.")
        return 1
    log("Flashe ESP32 %s an %s ..." % (role, port))
    exe, major = find_esptool()
    if not exe:
        log("FEHLER: esptool nicht gefunden (Arduino IDE mit ESP32-Paket nötig)")
        return 1
    log("esptool: " + exe)
    cmd = [exe, "--chip", "esp32s3", "-p", port, "-b", "921600",
           "write-flash" if major >= 5 else "write_flash", "0x0", binf]
    r = subprocess.run(cmd, capture_output=True, text=True)
    log(r.stdout[-1500:])
    if r.returncode != 0:
        log(r.stderr[-1500:])
        log("FEHLER beim Flashen (Code %d). Tipp: BOOT-Taste halten, RST drücken, BOOT loslassen, nochmal." % r.returncode)
        return 1
    if diag:
        log("Flashen OK. Mitschnitt der Startmeldungen:")
        return monitor(40, reset=True)
    log("Flashen OK. Warte auf Neustart ...")
    time.sleep(3)
    return info(port)


def info(port=None):
    import lrmodem
    port = port or find_port()
    if not port:
        log("FEHLER: kein ESP32 gefunden.")
        return 1
    m = lrmodem.LrModem(port, 115200)
    logs = []
    m.on_log = lambda lvl, t: logs.append(t)
    try:
        for i in range(25):
            try:
                v = m.ping()
                break
            except Exception as e:
                time.sleep(1)
        else:
            log("FEHLER: Modem antwortet nicht an %s" % port)
            return 1
        log("Modem antwortet (Protokoll v%d)" % v)
        for k, val in m.info().items():
            log("  %-18s %s" % (k, val))
        for k, val in m.config().items():
            log("  %-18s %s" % (k, val))
        for t in logs:
            log("  Meldung: " + t)
    finally:
        m.close()
    return 0


def hard_reset(s):
    """ESP32 über RTS (EN) neu starten. Nach jeder RTS-Änderung DTR neu setzen,
    sonst übernimmt der Windows-Treiber die Änderung nicht (wie esptool)."""
    s.dtr = False
    s.rts = True
    s.dtr = s.dtr
    time.sleep(0.15)
    s.rts = False
    s.dtr = s.dtr


def esptool_run(args, timeout=120):
    exe, major = find_esptool()
    if not exe:
        return None, "esptool nicht gefunden"
    if major < 5:
        args = [a.replace("-", "_") if a in ("flash-id", "read-flash", "chip-id") else a for a in args]
    r = subprocess.run([exe] + args, capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def analyse():
    """Prüft ESP32, Firmware, serielle Ausgabe und Modem-Antwort und fasst zusammen."""
    import serial, lrmodem
    befund = []
    log("### 1. Anschluss")
    port = find_port()
    if not port:
        log("FEHLER: kein ESP32 an USB gefunden.")
        return 1
    log("ESP32 an " + port)

    log("### 2. Chip und Speicher (esptool)")
    rc, out = esptool_run(["--chip", "esp32s3", "-p", port, "flash-id"])
    keep = [l for l in out.splitlines() if any(k in l for k in ("Chip", "Features", "Crystal", "MAC", "flash size", "Flash size", "Manufacturer", "PSRAM", "Embedded", "revision", "Error", "error", "Fatal", "A fatal"))]
    for l in keep:
        log("  " + l.strip())
    if rc != 0:
        befund.append("esptool konnte nicht mit dem Chip reden (USB/Boot-Modus)")
    else:
        txt = out.lower().replace(" ", "")
        if "detectedflashsize:2mb" in txt or "detectedflashsize:1mb" in txt:
            befund.append("Flash kleiner als 4 MB – Firmware passt nicht")

    log("### 3. Welche Firmware ist drauf?")
    tmp = os.path.join(HERE, "_flash_dump.bin")
    rc, out = esptool_run(["--chip", "esp32s3", "-p", port, "-b", "921600", "read-flash", "0x10000", "0x80000", tmp], timeout=180)
    rolle = None
    if rc == 0 and os.path.exists(tmp):
        data = open(tmp, "rb").read()
        i = data.find(b"LRMODEM fw ")
        if i >= 0:
            kennung = data[i:i + 40].split(b"\x00")[0].decode("latin-1")
            log("  gefunden: " + kennung)
            rolle = "A" if "role A" in kennung else "B" if "role B" in kennung else None
        else:
            log("  keine LR2021-Modem-Firmware erkannt")
            befund.append("auf dem ESP32 ist keine Modem-Firmware")
        try:
            os.remove(tmp)
        except OSError:
            pass
    else:
        log("  Flash konnte nicht gelesen werden")

    log("### 4. Startmeldungen (Neustart über USB, 25 s)")
    s = serial.Serial()
    s.port, s.baudrate, s.timeout = port, 115200, 0.2
    s.dtr = False
    s.rts = False
    s.open()
    hard_reset(s)
    t0, raw = time.time(), bytearray()
    while time.time() - t0 < 25:
        raw += s.read(512)
    s.close()
    rom = b"ESP-ROM" in raw or b"rst:" in raw
    frames = raw.count(b"\x00")
    text = bytes(b if 32 <= b < 127 or b in (10, 13) else 46 for b in raw).decode("ascii")
    for line in [l for l in text.splitlines() if l.strip()][:60]:
        log("  | " + line.rstrip())
    log("  empfangen: %d Byte, Bootmeldung: %s, Protokoll-Rahmen: ca. %d" % (len(raw), "ja" if rom else "nein", frames))
    if b"Guru Meditation" in raw or b"panic" in raw or b"abort()" in raw:
        befund.append("Firmware stürzt ab (siehe Startmeldungen)")
    if b"Brownout" in raw:
        befund.append("Brownout: Versorgungsspannung bricht ein (3,3 V / 5 V prüfen, Kurzschluss an 3V3?)")
    if raw.count(b"rst:") > 2:
        befund.append("ESP32 startet ständig neu")
    if len(raw) == 0:
        befund.append("ESP32 sendet gar nichts: läuft nicht (Reset/EN-Pin auf LOW? 3,3 V fehlt?) oder TX0 (GPIO43, Loch 22u bzw. 35u) wird belastet")

    log("### 5. Modem-Protokoll")
    ok = False
    try:
        m = lrmodem.LrModem(port, 115200, timeout=1.5)
        msgs = []
        m.on_log = lambda lvl, t: msgs.append(t)
        for _ in range(20):
            try:
                m.ping()
                ok = True
                break
            except Exception:
                time.sleep(0.5)
        if ok:
            info = m.info()
            for k, v in info.items():
                log("  %-18s %s" % (k, v))
            st = m.stats()
            log("  Statistik: " + ", ".join("%s=%s" % kv for kv in st.items()))
            if not info.get("radio_ok"):
                code = info.get("init_code")
                befund.append("LR2021 antwortet nicht (RadioLib-Code %s): %s" % (code, {
                    -2: "Chip nicht gefunden: CS, SCK, MOSI, MISO, RST, BUSY oder 3,3 V zum Modul prüfen",
                    -705: "SPI-Zeitüberschreitung: BUSY bleibt HIGH (BUSY-Leitung, RST, 3,3 V)",
                    -707: "Quarz/TCXO-Fehler"}.get(code, "siehe RadioLib-Fehlerliste")))
            if rolle and info.get("role") != rolle:
                befund.append("Rolle im Flash und laufende Rolle passen nicht zusammen")
        else:
            befund.append("Modem antwortet nicht auf Befehle")
        m.close()
    except Exception as e:
        log("  Fehler: %s" % e)
        befund.append("serielle Schnittstelle nicht nutzbar: %s" % e)

    log("### ERGEBNIS")
    if rolle:
        log("  Firmware im Flash: Rolle " + rolle)
    if not befund:
        log("  Alles in Ordnung.")
    for b in befund:
        log("  - " + b)
    return 0 if not befund else 1


def rxtest(minutes=5):
    """Stellt Meshtastic EU ein und zeigt empfangene Pakete (Strg+C beendet)."""
    import lrmodem
    port = find_port()
    if not port:
        log("FEHLER: kein ESP32 gefunden.")
        return 1
    m = lrmodem.LrModem(port, 115200)
    try:
        for _ in range(20):                    # ESP32 braucht nach dem Einstecken ein paar Sekunden
            try:
                m.ping()
                break
            except Exception:
                time.sleep(0.5)
        else:
            log("FEHLER: Modem antwortet nicht an %s. Erst 2_Info.bat bzw. 5_Analyze.bat ausführen." % port)
            return 1
        info = m.info()
        if info.get("role") == "A":
            p = lrmodem.PRESETS["meshtastic-eu"]
        else:
            p = lrmodem.PRESETS["test-433"]
        m.set_lora(p["freq"], p["bw"], p["sf"], p["cr"], p["sync"], 10, p["preamble"])
        m.on_rx = lambda ev: log(lrmodem._fmt_rx(ev))
        m.on_log = lambda lvl, t: log("  Meldung: " + t)
        m.on_boot = lambda ev: log("  !! ESP32 hat neu gestartet")
        m.rx_start()
        log("Empfange %d min auf %.3f MHz (ESP32 %s) ..." % (minutes, p["freq"], info.get("role")))
        t0 = time.time()
        while time.time() - t0 < minutes * 60:
            time.sleep(15)
            try:
                st = m.stats()
                log("  %3d s: %d Pakete, %d CRC-Fehler, RSSI jetzt %.0f dBm" % (
                    time.time() - t0, st["rx_ok"], st["rx_crc_error"], m.rssi()))
            except Exception as e:
                log("  %3d s: keine Antwort (%s)" % (time.time() - t0, e))
        st = m.stats()
        log("Empfangen: %d Pakete ok, %d mit CRC-Fehler" % (st["rx_ok"], st["rx_crc_error"]))
        m.standby()
    except KeyboardInterrupt:
        pass
    finally:
        m.close()
    return 0


def scan(sekunden=60):
    """Probiert nacheinander die üblichen Meshtastic/MeshCore-Einstellungen durch und zählt Pakete."""
    import lrmodem
    port = find_port()
    if not port:
        log("FEHLER: kein ESP32 gefunden.")
        return 1
    m = lrmodem.LrModem(port, 115200)
    m.on_rx = lambda ev: log("    " + lrmodem._fmt_rx(ev))
    m.on_log = lambda lvl, t: log("    Meldung: " + t)
    ergebnis = []
    try:
        for _ in range(20):
            try:
                m.ping(); break
            except Exception:
                time.sleep(0.5)
        if m.info().get("role") != "A":
            log("Suchlauf ist für ESP32 A (868) gedacht.")
            return 1
        for name in ("meshtastic-eu", "meshtastic-eu-mf", "meshtastic-eu-ms", "meshtastic-eu-sf",
                     "meshtastic-eu-ss", "meshcore-eu"):
            p = lrmodem.PRESETS[name]
            m.set_lora(p["freq"], p["bw"], p["sf"], p["cr"], p["sync"], 10, p["preamble"])
            m.reset_stats()
            m.rx_start()
            log("  %-18s %.3f MHz BW %g SF%d ... %d s" % (name, p["freq"], p["bw"], p["sf"], sekunden))
            t0, maxr = time.time(), -200
            while time.time() - t0 < sekunden:
                time.sleep(2)
                try:
                    maxr = max(maxr, m.rssi())
                except Exception:
                    pass
            st = m.stats()
            ergebnis.append((name, st["rx_ok"], st["rx_crc_error"], maxr))
            log("    -> %d Pakete, %d CRC-Fehler, stärkstes Signal %.0f dBm" % (st["rx_ok"], st["rx_crc_error"], maxr))
        m.standby()
    finally:
        m.close()
    log("### ERGEBNIS Suchlauf")
    for n, ok, crc, r in ergebnis:
        log("  %-18s %3d Pakete  %3d CRC-Fehler  max %.0f dBm" % (n, ok, crc, r))
    return 0


def txtest():
    """Sendet 3 kurze Testpakete (10 dBm) und prüft die Bestätigung vom Funkchip."""
    import lrmodem
    port = find_port()
    if not port:
        log("FEHLER: kein ESP32 gefunden.")
        return 1
    m = lrmodem.LrModem(port, 115200)
    m.on_log = lambda lvl, t: log("  Meldung: " + t)
    rc = 0
    try:
        for _ in range(20):
            try:
                m.ping(); break
            except Exception:
                time.sleep(0.5)
        role = m.info().get("role")
        p = lrmodem.PRESETS["test-868" if role == "A" else "test-433"]
        m.set_lora(p["freq"], p["bw"], p["sf"], p["cr"], p["sync"], 10, p["preamble"])
        log("Sende 3 Testpakete auf %.3f MHz, 10 dBm (ESP32 %s) ..." % (p["freq"], role))
        for i in range(3):
            ev = m.tx_wait("LR2021 Test %d" % (i + 1), timeout=10)
            log("  Paket %d: %s, Sendezeit %.1f ms" % (i + 1, ev["status_text"], ev["airtime_us"] / 1000))
            if ev["status"] != 0:
                rc = 1
            time.sleep(2)
        st = m.stats()
        log("  gesendet ok: %d, fehlgeschlagen: %d" % (st["tx_ok"], st["tx_fail"]))
        m.standby()
    except Exception as e:
        log("FEHLER: %s" % e)
        rc = 1
    finally:
        m.close()
    return rc


def mesh():
    """Meshtastic LongFast: Nachrichten mitlesen (entschlüsselt) und selbst Text senden."""
    import lrmodem, meshtastic, random
    port = find_port()
    if not port:
        log("FEHLER: kein ESP32 gefunden.")
        return 1
    m = lrmodem.LrModem(port, 115200)
    try:
        for _ in range(20):
            try:
                m.ping(); break
            except Exception:
                time.sleep(0.5)
        info = m.info()
        if info.get("role") != "A":
            log("Meshtastic EU läuft auf 868 MHz: bitte ESP32 A anstecken.")
            return 1
        p = lrmodem.PRESETS["meshtastic-eu"]
        m.set_lora(p["freq"], p["bw"], p["sf"], p["cr"], p["sync"], 14, p["preamble"])
        dec = meshtastic.MeshtasticDecoder()
        my = 0x4C520000 | (int(info["chip_id"], 16) & 0xFFFF)
        seen = {}

        def on_rx(ev):
            dbg("RX %s B rssi=%.1f snr=%.1f df=%d crc_err=%s hex=%s" % (len(ev["data"]), ev["rssi"], ev["snr"],
                ev["freq_error"], ev["crc_error"], ev["data"].hex()))
            if ev["crc_error"]:
                log("%s  (Paket mit CRC-Fehler, %d B, %.0f dBm)" % (time.strftime("%H:%M:%S"), len(ev["data"]), ev["rssi"]))
                return
            try:
                d = dec.decode(ev["data"])
            except Exception as e:
                import traceback
                dbg("DECODE-FEHLER " + traceback.format_exc())
                log("%s  (Paket nicht lesbar: %s)" % (time.strftime("%H:%M:%S"), e))
                return
            dbg("DECODED", d)
            if d.get("von") == "!%08x" % my:
                k = ("ich", d.get("id"))
                if k not in seen:
                    seen[k] = time.time()
                    log("%s  ✓ weitergeleitet von Knoten …%02x   (%.0f dBm, SNR %.1f)" % (
                        time.strftime("%H:%M:%S"), d.get("relay", 0), ev["rssi"], ev["snr"]))
                return
            k = (d.get("von"), d.get("id"))
            if k in seen:
                dbg("DUPLIKAT", k)
                return                                   # Wiederholung (anderer Knoten hat weitergeleitet)
            seen[k] = time.time()
            log("%s  %s   (%.0f dBm, SNR %.1f)" % (time.strftime("%H:%M:%S"), meshtastic.format_packet(d),
                                                   ev["rssi"], ev["snr"]))
            if d.get("app") == "NODEINFO" and d.get("an") == "!%08x" % my:
                von = int(d["von"][1:], 16)
                if time.time() - nodeinfo_gesendet.get(von, 0) > 600:
                    nodeinfo_gesendet[von] = time.time()
                    sende_nodeinfo(an=von)

        import queue as _q, threading
        txq = _q.Queue()                                  # alles Senden läuft über einen eigenen Thread

        def tx_worker():
            while m._running:
                try:
                    pk, beschreibung = txq.get(timeout=0.5)
                except _q.Empty:
                    continue
                dbg("TX %s hex=%s" % (beschreibung, pk.hex()))
                try:
                    ev = m.tx_wait(pk, lbt=MESH_LBT, timeout=15)
                    log("%s  %s  (%s, %.0f ms)" % (time.strftime("%H:%M:%S"), beschreibung,
                                                  ev["status_text"], ev["airtime_us"] / 1000))
                except Exception as e:
                    import traceback
                    dbg("TX-FEHLER " + traceback.format_exc())
                    log("Senden fehlgeschlagen (%s): %s" % (beschreibung, e))
        threading.Thread(target=tx_worker, daemon=True).start()

        nodeinfo_gesendet = {}

        def sende_nodeinfo(an=0xFFFFFFFF, antwort_erbeten=False):
            pk = meshtastic.build_nodeinfo_packet(my, random.randint(1, 0xFFFFFFFF), MESH_NAME_LANG, MESH_NAME_KURZ,
                                                  dest=an, want_response=antwort_erbeten)
            ziel = "alle" if an == 0xFFFFFFFF else "!%08x" % an
            txq.put((pk, "ICH -> %s: Visitenkarte »%s«" % (ziel, MESH_NAME_LANG)))

        m.on_rx = on_rx
        m.on_log = lambda lvl, t: log("  Meldung: " + t)
        m.on_boot = lambda ev: log("  !! ESP32 hat neu gestartet: %s" % ev)
        m.on_tx_done = lambda ev: dbg("TX_DONE", ev)
        dbg("INFO", info)
        dbg("CONFIG", m.config())
        m.rx_start()

        def stats_loop():
            while m._running:
                time.sleep(60)
                try:
                    dbg("STATS", m.stats(), "bad_frames_pc=%d" % m.bad_frames)
                except Exception as e:
                    log("  !! Modem antwortet nicht auf Statusabfrage: %s" % e)
        import threading
        threading.Thread(target=stats_loop, daemon=True).start()
        log("Debug-Log: " + DEBUG_LOG)
        sende_nodeinfo(antwort_erbeten=True)              # beim Start bekannt machen

        def nodeinfo_loop():
            while m._running:
                time.sleep(3 * 3600)
                sende_nodeinfo()
        threading.Thread(target=nodeinfo_loop, daemon=True).start()
        log("Meshtastic LongFast, 869,525 MHz. Eigene Knoten-ID: !%08x, Name »%s« (%s)" % (my, MESH_NAME_LANG, MESH_NAME_KURZ))
        log("Text eintippen + Enter sendet an alle. Leere Eingabe = nichts, 'ende' beendet.")
        while True:
            try:
                line = input()
            except EOFError:
                break
            line = line.strip()
            if not line:
                continue
            if line.lower() in ("ende", "exit", "quit", "q"):
                break
            teile, rest = [], line
            while rest:                                   # max. 200 Byte pro Nachricht, an Zeichengrenzen
                n = len(rest)
                while len(rest[:n].encode("utf-8")) > 200:
                    n -= 1
                teile.append(rest[:n])
                rest = rest[n:]
            if len(teile) > 1:
                log("  (Text ist lang, wird in %d Nachrichten geteilt)" % len(teile))
            for teil in teile:
                pk = meshtastic.build_text_packet(teil, my, random.randint(1, 0xFFFFFFFF))
                txq.put((pk, "ICH -> alle: »%s«" % teil))
        time.sleep(1)
        m.standby()
    finally:
        m.close()
    return 0


def monitor(seconds=20, reset=False):
    """Rohausgabe des ESP32 mitschreiben (ohne Reset), Rahmen dekodieren."""
    import serial, lrmodem
    port = find_port()
    if not port:
        log("FEHLER: kein ESP32 gefunden.")
        return 1
    s = serial.Serial()
    s.port, s.baudrate, s.timeout = port, 115200, 0.2
    s.dtr = False
    s.rts = False
    s.open()
    if reset:
        hard_reset(s)
    log("Mitschnitt %s für %d s ... (jetzt RST am ESP32 drücken)" % (port, seconds))
    t0, buf, text = time.time(), bytearray(), bytearray()
    while time.time() - t0 < seconds:
        for b in s.read(256):
            if b == 0:
                if buf:
                    try:
                        ft, seq, pl = lrmodem.parse_frame(bytes(buf))
                        ev = lrmodem.LrModem._decode_event(ft, pl)
                        log("  [Rahmen 0x%02X] %s" % (ft, ev if ev else pl.hex()))
                    except Exception:
                        text.extend(buf)
                buf = bytearray()
            else:
                buf.append(b)
        # Klartext (Bootmeldungen) zeilenweise ausgeben
        while b"\n" in text:
            line, _, rest = bytes(text).partition(b"\n")
            text = bytearray(rest)
            log("  | " + line.decode("latin-1").rstrip())
    if text:
        log("  | " + bytes(text).decode("latin-1"))
    if buf:
        log("  | " + bytes(buf).decode("latin-1"))
    s.close()
    return 0


def main():
    _install_crash_logging()
    with open(LOG, "a", encoding="utf-8") as f:
        f.write("\n===== %s  %s\n" % (datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), " ".join(sys.argv[1:])))
    if len(sys.argv) >= 3 and sys.argv[1] == "flash" and sys.argv[2] in ("A", "B"):
        rc = flash(sys.argv[2])
    elif len(sys.argv) >= 2 and sys.argv[1] == "mesh":
        rc = mesh()
    elif len(sys.argv) >= 2 and sys.argv[1] == "tx":
        rc = txtest()
    elif len(sys.argv) >= 2 and sys.argv[1] == "scan":
        rc = scan()
    elif len(sys.argv) >= 2 and sys.argv[1] == "rx":
        rc = rxtest()
    elif len(sys.argv) >= 2 and sys.argv[1] == "analyse":
        rc = analyse()
    elif len(sys.argv) >= 2 and sys.argv[1] == "diag":
        rc = flash("A", diag=True)
    elif len(sys.argv) >= 2 and sys.argv[1] == "monitor":
        rc = monitor()
    elif len(sys.argv) >= 2 and sys.argv[1] == "info":
        rc = info()
    else:
        print(__doc__)
        rc = 2
    log("FERTIG" if rc == 0 else "NICHT OK")
    return rc


if __name__ == "__main__":
    sys.exit(main())
