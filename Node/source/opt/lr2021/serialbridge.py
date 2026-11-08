#!/usr/bin/env python3
"""LR2021 Seriell-Brücke: Modems und GPS über die serielle Konsole (CP2102, ttyS0, 115200).

Die PC-App meldet sich an der Konsole an und startet:   exec python3 /opt/lr2021/serialbridge.py
Danach spricht die Leitung nur noch Rahmen (bis das Programm endet und wieder „login:“ erscheint):

    [Kanal] [Daten …] 0x00
    Kanal 1 = ESP32 A (TCP 2021), 2 = ESP32 B (TCP 2022): Daten = ein COBS-Rahmen des Modem-Protokolls
    Kanal 3 = GPS (TCP 2023, nur Pi -> PC, eine NMEA-Zeile je Rahmen, erst nach „G“)
    Kanal 0x7F = Steuerung: 'P' Ping -> Antwort 'p'; 'G' GPS an; 'g' GPS aus; 'Q' Ende

COBS-Rahmen enthalten kein 0x00, deshalb reicht 0x00 als Trenner. Kommt 90 s nichts vom PC, endet die
Brücke von selbst und die Konsole ist wieder normal benutzbar.
"""
import os
import select
import socket
import sys
import termios
import time
import tty

VERSION = "1"
PORTS = {1: 2021, 2: 2022, 3: 2023}
CTRL = 0x7F
IDLE_S = 90


def write_all(fd, data):
    while data:
        n = os.write(fd, data)
        data = data[n:]


def main():
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
    socks, last_try, bufs = {}, {}, {1: b"", 2: b"", 3: b""}
    gps_on = False
    inbuf = b""
    last_rx = time.monotonic()
    try:
        write_all(fout, b"\r\nLRB" + VERSION.encode() + b"\r\n")
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
            r, _, _ = select.select([fin] + list(socks.values()), [], [], 1.0)
            if fin in r:
                d = os.read(fin, 4096)
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
                            write_all(fout, bytes([CTRL]) + b"p" + VERSION.encode() + b"\x00")
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
                    if s is not None and ch in (1, 2):
                        try:
                            s.sendall(fr[1:] + b"\x00")
                        except OSError:
                            s.close()
                            socks.pop(ch, None)
                if quit_:
                    break
                if len(inbuf) > 8192:
                    inbuf = b""  # Müll ohne Trenner verwerfen
            for ch, s in list(socks.items()):
                if s not in r:
                    continue
                try:
                    d = s.recv(4096)
                except OSError:
                    d = b""
                if not d:
                    s.close()
                    socks.pop(ch, None)
                    bufs[ch] = b""
                    continue
                if ch == 3:  # NMEA: zeilenweise
                    bufs[3] += d
                    while b"\n" in bufs[3]:
                        line, bufs[3] = bufs[3].split(b"\n", 1)
                        line = line.strip().replace(b"\x00", b"")
                        if line:
                            write_all(fout, b"\x03" + line + b"\x00")
                    if len(bufs[3]) > 4096:
                        bufs[3] = b""
                    continue
                bufs[ch] += d
                while b"\x00" in bufs[ch]:
                    fr, bufs[ch] = bufs[ch].split(b"\x00", 1)
                    if fr:
                        write_all(fout, bytes([ch]) + fr + b"\x00")
            if time.monotonic() - last_rx > IDLE_S:
                break
    finally:
        for s in socks.values():
            try:
                s.close()
            except OSError:
                pass
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
