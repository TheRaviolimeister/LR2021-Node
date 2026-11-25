#!/usr/bin/env python3
"""LR2021 Brücke: Modems, GPS und Postfach über EINE Verbindung.

Seriell (Konsole CP2102/CH340, ttyS0, 115200): Die PC-App meldet sich an der Konsole an und startet
    exec python3 /opt/lr2021/serialbridge.py
Bluetooth: lr2021d startet dieselbe Brücke für jede Verbindung auf dem Bluetooth-Sammelkanal (RFCOMM 5,
der als serielle Standard-Schnittstelle „SPP“ angemeldet ist) – dort ohne Anmeldung.

Danach spricht die Leitung nur noch Rahmen:

    [Kanal] [Daten …] 0x00
    Kanal 1 = ESP32 A (TCP 2021), 2 = ESP32 B (TCP 2022): Daten = ein COBS-Rahmen des Modem-Protokolls
    Kanal 3 = GPS (TCP 2023, nur Node -> App, eine NMEA-Zeile je Rahmen, erst nach „G“)
    Kanal 4 = Postfach (TCP 2024): eine JSON-Zeile je Rahmen (ab Version 2)
    Kanal 0x7F = Steuerung: 'P' Ping -> Antwort 'p' + Version; 'G' GPS an; 'g' GPS aus; 'Q' Ende

COBS-Rahmen und JSON enthalten kein 0x00, deshalb reicht 0x00 als Trenner. Kommt [IDLE_S] s nichts von der App,
endet die Brücke von selbst (die Konsole ist dann wieder normal benutzbar).
"""
import os
import select
import socket
import sys
import time

VERSION = "2"
PORTS = {1: 2021, 2: 2022, 3: 2023, 4: 2024}
LINE_CH = (3, 4)          # Kanäle, deren TCP-Seite zeilenweise spricht
CTRL = 0x7F
IDLE_S = 90


def run_bridge(src, read, write, idle_s=IDLE_S):
    """Brücke betreiben. [src] muss für select() taugen, [read]() liefert Bytes (b"" = Ende), [write](bytes)."""
    socks, last_try, bufs = {}, {}, {ch: b"" for ch in PORTS}
    gps_on = False
    inbuf = b""
    last_rx = time.monotonic()
    try:
        while True:
            now = time.monotonic()
            for ch, port in PORTS.items():
                if ch == 3 and not gps_on:
                    continue
                if ch not in socks and now - last_try.get(ch, 0) > 2:
                    last_try[ch] = now
                    try:
                        socks[ch] = socket.create_connection(("127.0.0.1", port), timeout=1)
                        socks[ch].settimeout(None)
                    except OSError:
                        pass
            r, _, _ = select.select([src] + list(socks.values()), [], [], 1.0)
            if src in r:
                d = read()
                if not d:
                    break
                last_rx = time.monotonic()
                inbuf += d
                quit_ = False
                while b"\x00" in inbuf:
                    fr, inbuf = inbuf.split(b"\x00", 1)
                    if not fr:
                        continue
                    ch = fr[0]
                    if ch == CTRL:
                        cmd = fr[1:2]
                        if cmd == b"P":
                            write(bytes([CTRL]) + b"p" + VERSION.encode() + b"\x00")
                        elif cmd == b"G":
                            gps_on = True
                        elif cmd == b"g":
                            gps_on = False
                            s = socks.pop(3, None)
                            if s:
                                s.close()
                        elif cmd == b"Q":
                            quit_ = True
                        continue
                    s = socks.get(ch)
                    if s is not None and ch in (1, 2, 4):
                        try:
                            s.sendall(fr[1:] + (b"\n" if ch == 4 else b"\x00"))
                        except OSError:
                            s.close()
                            socks.pop(ch, None)
                if quit_:
                    break
                if len(inbuf) > 6 * 1024 * 1024:
                    inbuf = b""  # Müll ohne Trenner verwerfen
            for ch, s in list(socks.items()):
                if s not in r:
                    continue
                try:
                    d = s.recv(65536)
                except OSError:
                    d = b""
                if not d:
                    s.close()
                    socks.pop(ch, None)
                    bufs[ch] = b""
                    continue
                bufs[ch] += d
                if ch in LINE_CH:  # NMEA bzw. JSON: zeilenweise
                    while b"\n" in bufs[ch]:
                        line, bufs[ch] = bufs[ch].split(b"\n", 1)
                        line = line.strip().replace(b"\x00", b"")
                        if line:
                            write(bytes([ch]) + line + b"\x00")
                    if len(bufs[ch]) > 8 * 1024 * 1024:
                        bufs[ch] = b""
                    continue
                while b"\x00" in bufs[ch]:
                    fr, bufs[ch] = bufs[ch].split(b"\x00", 1)
                    if fr:
                        write(bytes([ch]) + fr + b"\x00")
            if idle_s and time.monotonic() - last_rx > idle_s:
                break
    finally:
        for s in socks.values():
            try:
                s.close()
            except OSError:
                pass


def write_all(fd, data):
    while data:
        n = os.write(fd, data)
        data = data[n:]


def main():
    import termios
    import tty
    fin, fout = sys.stdin.fileno(), sys.stdout.fileno()
    try:
        old = termios.tcgetattr(fin)
    except termios.error:
        print("Nur auf einer seriellen Konsole benutzbar.")
        return 1
    printk = None
    try:  # Kernel-Meldungen auf der Konsole abschalten (würden die Rahmen stören)
        with open("/proc/sys/kernel/printk") as f:
            printk = f.read().split()
        with open("/proc/sys/kernel/printk", "w") as f:
            f.write("1")
    except OSError:
        pass
    tty.setraw(fin)
    try:
        write_all(fout, b"\r\nLRB1\r\n")   # Startmeldung (die App wartet auf „LRB1“)
        run_bridge(fin, lambda: os.read(fin, 65536), lambda b: write_all(fout, b))
    finally:
        termios.tcsetattr(fin, termios.TCSADRAIN, old)
        if printk:
            try:
                with open("/proc/sys/kernel/printk", "w") as f:
                    f.write(printk[0])
            except OSError:
                pass
        try:
            write_all(fout, b"\r\nLRB-ENDE\r\n")
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
