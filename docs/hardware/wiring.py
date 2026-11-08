#!/usr/bin/env python3
"""Draws the LR2021 Node wiring diagram (wiring.svg) from the pin tables.
Usage: python3 wiring.py  -> writes wiring.svg next to this script.
The pin assignment must match firmware/lr2021_modem/config.h."""
import os

W, H = 1200, 860
C = {"5v": "#d23b2f", "gnd": "#1f2a27", "3v3": "#d98a00", "uart": "#1f6fd1", "gps": "#16925a", "spi": "#7b4bc4",
     "box": "#ffffff", "edge": "#3c4a45", "muted": "#5b6964", "bg": "#f6f8f7"}

out = []


def add(s):
    out.append(s)


def box(x, y, w, h, title, sub=""):
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{C["box"]}" stroke="{C["edge"]}" stroke-width="1.6"/>')
    add(f'<text x="{x + w / 2}" y="{y + 22}" text-anchor="middle" font-size="15" font-weight="700">{title}</text>')
    if sub:
        add(f'<text x="{x + w / 2}" y="{y + 40}" text-anchor="middle" font-size="11.5" fill="{C["muted"]}">{sub}</text>')


def pin(x, y, label, side, color):
    add(f'<circle cx="{x}" cy="{y}" r="4" fill="{color}"/>')
    anchor = "start" if side == "r" else "end"
    dx = 8 if side == "r" else -8
    add(f'<text x="{x + dx}" y="{y + 4}" text-anchor="{anchor}" font-size="11.5" font-family="monospace">{label}</text>')


def wire(pts, color, label=None, at=0):
    d = "M" + " L".join(f"{x} {y}" for x, y in pts)
    add(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="2.2" stroke-linejoin="round"/>')
    if label:
        (x1, y1), (x2, y2) = pts[at], pts[at + 1]
        add(f'<text x="{(x1 + x2) / 2}" y="{(y1 + y2) / 2 - 5}" text-anchor="middle" font-size="10.5" fill="{color}">{label}</text>')


add(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" font-family="Helvetica, Arial, sans-serif">')
add(f'<rect width="{W}" height="{H}" fill="{C["bg"]}"/>')
add('<text x="24" y="36" font-size="22" font-weight="700">LR2021 Node – wiring</text>')
add(f'<text x="24" y="58" font-size="13" fill="{C["muted"]}">Orange Pi Zero 2W · 2× ESP32-S3 DevKitC-1 · Core2021-HF / Core2021-LF (LR2021) · GPS L76X · CP2102</text>')

# ---------------------------------------------------------------- Orange Pi
px, py, pw, ph = 470, 110, 220, 470
box(px, py, pw, ph, "Orange Pi Zero 2W", "40-pin header")
pi_pins = [  # (pin, name, colour)
    (2, "5V", C["5v"]), (4, "5V", C["5v"]), (6, "GND", C["gnd"]), (8, "TXD0", C["uart"]), (10, "RXD0", C["uart"]),
    (9, "GND", C["gnd"]), (11, "TXD5", C["gps"]), (13, "RXD5", C["gps"]), (15, "PI5 (PPS)", C["gps"]), (17, "3V3", C["3v3"]),
    (28, "TXD3", C["uart"]), (27, "RXD3", C["uart"]), (7, "TXD4", C["uart"]), (16, "RXD4", C["uart"]), (30, "GND", C["gnd"]),
]
pp = {}
for i, (n, name, col) in enumerate(pi_pins):
    y = py + 70 + i * 26
    left = n in (2, 4, 6, 8, 10, 9, 11, 13, 15, 17)
    x = px if left else px + pw
    pin(x, y, f"{n} {name}", "r" if left else "l", col)
    pp[n] = (x, y)

# ---------------------------------------------------------------- left: power, CP2102, GPS
box(40, 100, 230, 110, "5 V power supply", "USB-C power supply or 4×18650 shield")
pin(270, 150, "+5V", "l", C["5v"])
pin(270, 182, "GND", "l", C["gnd"])
wire([(270, 150), (380, 150), (380, pp[2][1]), pp[2]], C["5v"], "5 V", 0)
wire([(380, pp[2][1]), (380, pp[4][1]), pp[4]], C["5v"])
wire([(270, 182), (360, 182), (360, pp[6][1]), pp[6]], C["gnd"])

box(40, 240, 230, 120, "CP2102 (USB-serial)", "console 115200 baud")
pin(270, 290, "RXD", "l", C["uart"])
pin(270, 314, "TXD", "l", C["uart"])
pin(270, 338, "GND", "l", C["gnd"])
wire([(270, 290), (400, 290), (400, pp[8][1]), pp[8]], C["uart"])
wire([(270, 314), (410, 314), (410, pp[10][1]), pp[10]], C["uart"])
wire([(270, 338), (350, 338), (350, pp[6][1])], C["gnd"])
add(f'<text x="155" y="378" text-anchor="middle" font-size="11" fill="{C["5v"]}">do not connect 5V/3V3 of the CP2102</text>')

box(40, 400, 230, 160, "GPS L76X", "9600 baud, NMEA")
for i, (lab, n, col) in enumerate([("GND", 9, C["gnd"]), ("RX", 11, C["gps"]), ("TX", 13, C["gps"]), ("PPS", 15, C["gps"]), ("VCC", 17, C["3v3"])]):
    y = 450 + i * 22
    pin(270, y, lab, "l", col)
    wire([(270, y), (300 + i * 14, y), (300 + i * 14, pp[n][1]), pp[n]], col)

# ---------------------------------------------------------------- ESP32 A / B
def esp(x, y, name, uart_tx_pin, uart_rx_pin, lr):
    box(x, y, 210, 300, name, "ESP32-S3 DevKitC-1")
    pin(x, y + 70, "GPIO1 RX", "r", C["uart"])
    pin(x, y + 96, "GPIO2 TX", "r", C["uart"])
    pin(x, y + 270, "GND", "r", C["gnd"])
    pin(x, y + 244, "5V", "r", C["5v"])
    # to the Pi
    wire([(x, y + 70), (x - 60, y + 70), (x - 60, pp[uart_tx_pin][1]), pp[uart_tx_pin]], C["uart"])
    wire([(x, y + 96), (x - 45, y + 96), (x - 45, pp[uart_rx_pin][1]), pp[uart_rx_pin]], C["uart"])
    # to the LR2021
    sig = [("CS", lr["CS"]), ("SCK", lr["SCK"]), ("MOSI", lr["MOSI"]), ("MISO", lr["MISO"]), ("RST", lr["RST"]),
           ("BUSY", lr["BUSY"]), ("IRQ", lr["IRQ"]), ("3V3", "3V3"), ("GND", "GND")]
    for i, (s, g) in enumerate(sig):
        yy = y + 64 + i * 24
        col = C["3v3"] if s == "3V3" else (C["gnd"] if s == "GND" else C["spi"])
        lab = g if s in ("3V3", "GND") else f"GPIO{g}"
        pin(x + 210, yy, lab, "l", col)
        wire([(x + 210, yy), (x + 290, yy)], col)
        pin(x + 290, yy, "DIO11" if s == "IRQ" else s, "r", col)
    return (x, y + 270), (x, y + 244)


A = dict(CS=17, IRQ=4, RST=6, BUSY=5, MISO=7, MOSI=15, SCK=16)
B = dict(CS=18, IRQ=10, RST=7, BUSY=15, MISO=6, MOSI=16, SCK=17)
box(1090, 110, 100, 290, "LR2021", "")
add(f'<text x="1140" y="370" text-anchor="middle" font-size="12" fill="{C["muted"]}">Core2021-HF</text>')
add(f'<text x="1140" y="387" text-anchor="middle" font-size="11" fill="{C["muted"]}">868 MHz</text>')
box(1090, 450, 100, 290, "LR2021", "")
add(f'<text x="1140" y="710" text-anchor="middle" font-size="12" fill="{C["muted"]}">Core2021-LF</text>')
add(f'<text x="1140" y="727" text-anchor="middle" font-size="11" fill="{C["muted"]}">433 MHz</text>')
ga, va = esp(800, 90, "ESP32 A", 28, 27, A)
gb, vb = esp(800, 430, "ESP32 B", 7, 16, B)
# ground of both ESP32 to Pi pin 30
wire([pp[30], (740, pp[30][1]), (740, gb[1]), gb], C["gnd"], "GND", 1)
wire([(740, ga[1]), ga], C["gnd"])
wire([(740, pp[30][1]), (740, ga[1])], C["gnd"])
# 5 V of the ESP32 from the 5 V rail
wire([(380, pp[4][1]), (380, 600), (760, 600), (760, va[1]), va], C["5v"])
wire([(760, 600), (760, vb[1]), vb], C["5v"])

# ---------------------------------------------------------------- legend
ly = 790
for i, (k, t) in enumerate([("5v", "5 V"), ("gnd", "GND"), ("3v3", "3.3 V"), ("uart", "UART"), ("gps", "GPS"), ("spi", "SPI / control lines")]):
    x = 40 + i * 150
    add(f'<line x1="{x}" y1="{ly}" x2="{x + 34}" y2="{ly}" stroke="{C[k]}" stroke-width="4"/>')
    add(f'<text x="{x + 42}" y="{ly + 4}" font-size="12.5">{t}</text>')
add(f'<text x="40" y="{ly + 34}" font-size="12" fill="{C["muted"]}">All signals 3.3 V. The LR2021 modules are powered from the 3V3 pin of their ESP32. '
    f'Always connect the antennas before transmitting.</text>')
add("</svg>")

open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "wiring.svg"), "w", encoding="utf-8").write("\n".join(out))
print("wiring.svg written")
