#!/usr/bin/env python3
"""Independent checks of the generated carrier board (run after generate_board.py).

1. Every connection is compared with the pin names of the real parts (ESP32-S3-DevKitC-1, Core2021,
   Orange Pi Zero 2W header, LR2021 modem firmware pins). A wrong pad number shows up here even if the
   design rule check is clean.
2. Track length of every net compared with the shortest possible connection.
3. Distance between the outlines (courtyards) of all parts.
"""
import itertools
import math
import os
import sys

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
board = pcbnew.LoadBoard(os.path.join(HERE, "lr2021-carrier.kicad_pcb"))
mm = pcbnew.ToMM

# ---- pin names ----------------------------------------------------------------------------------
DEVKIT_J1 = ["3V3", "3V3", "RST", "GPIO4", "GPIO5", "GPIO6", "GPIO7", "GPIO15", "GPIO16", "GPIO17", "GPIO18",
             "GPIO8", "GPIO3", "GPIO46", "GPIO9", "GPIO10", "GPIO11", "GPIO12", "GPIO13", "GPIO14", "5V", "GND"]
DEVKIT_J3 = ["GND", "GPIO43", "GPIO44", "GPIO1", "GPIO2", "GPIO42", "GPIO41", "GPIO40", "GPIO39", "GPIO38",
             "GPIO37", "GPIO36", "GPIO35", "GPIO0", "GPIO45", "GPIO48", "GPIO47", "GPIO21", "GPIO20", "GPIO19",
             "GND", "GND"]
CORE = ["2.4G_ANT", "GND", "DIO11", "DIO8", "DIO7", "NC", "GND", "3V3",
        "LORA_ANT", "GND", "CS", "CLK", "MOSI", "MISO", "RESET", "BUSY"]
# Orange Pi Zero 2W, physical pin -> function (wiringOP physToGpio table, H618 pin names)
PI = {1: "3V3", 2: "5V", 3: "PI8 I2C1_SDA", 4: "5V", 5: "PI7 I2C1_SCL", 6: "GND", 7: "PI13 UART4_TX",
      8: "PH0 UART0_TX", 9: "GND", 10: "PH1 UART0_RX", 11: "PH2 UART5_TX", 12: "PI1", 13: "PH3 UART5_RX",
      14: "GND", 15: "PI5", 16: "PI14 UART4_RX", 17: "3V3", 18: "PH4", 19: "PH7", 20: "GND", 21: "PH8",
      22: "PI6", 23: "PH6", 24: "PH5", 25: "GND", 26: "PH9", 27: "PI10 UART3_RX", 28: "PI9 UART3_TX",
      29: "PI0", 30: "GND", 31: "PI15", 32: "PI11", 33: "PI12", 34: "GND", 35: "PI2", 36: "PC12",
      37: "PI16", 38: "PI4", 39: "GND", 40: "PI3"}


def pin_name(ref, pad):
    if ref in ("U1", "U2"):
        n = int(pad)
        return ("J1-%d " % n + DEVKIT_J1[n - 1]) if n <= 22 else ("J3-%d " % (n - 22) + DEVKIT_J3[n - 23])
    if ref in ("U3", "U4"):
        return CORE[int(pad) - 1]
    if ref == "U5":
        return "pin %s %s" % (pad, PI[int(pad)])
    return pad


# what must be connected (signal by signal, written from the data sheets / firmware, not from the generator)
FW = {"U1": {"CS": "GPIO17", "CLK": "GPIO16", "MOSI": "GPIO15", "MISO": "GPIO7", "RESET": "GPIO6",
             "BUSY": "GPIO5", "DIO11": "GPIO4", "DIO7": "GPIO8", "DIO8": "GPIO9"},
      "U2": {"CS": "GPIO18", "CLK": "GPIO17", "MOSI": "GPIO16", "MISO": "GPIO6", "RESET": "GPIO7",
             "BUSY": "GPIO15", "DIO11": "GPIO10", "DIO7": "GPIO8", "DIO8": "GPIO9"}}
pads = {}
for fp in board.GetFootprints():
    for p in fp.Pads():
        if p.GetNumber():
            pads.setdefault((fp.GetReference(), p.GetNumber()), set()).add(p.GetNetname())


def net_of(ref, pad):
    s = pads[(ref, pad)]
    assert len(s) == 1, (ref, pad, s)
    return next(iter(s))


def members(net):
    return sorted({(r, p) for (r, p), ns in pads.items() if net in ns})


def devkit_pad(name):
    for i, n in enumerate(DEVKIT_J1):
        if n == name:
            return str(i + 1)
    for i, n in enumerate(DEVKIT_J3):
        if n == name:
            return str(i + 23)
    raise KeyError(name)


errors = []


def expect_same(a, b, what):
    na, nb = net_of(*a), net_of(*b)
    ok = na == nb and na != ""
    if not ok:
        errors.append(f"{what}: {a} ({na}) != {b} ({nb})")
    return ok


def expect_via(a, b, part, what):
    """a - part - b (series resistor)."""
    na, nb = net_of(*a), net_of(*b)
    p1, p2 = net_of(part, "1"), net_of(part, "2")
    if {na, nb} != {p1, p2} or na == nb:
        errors.append(f"{what}: {a} ({na}) - {part} ({p1}/{p2}) - {b} ({nb})")


rows = []
for esp, core in (("U1", "U3"), ("U2", "U4")):
    for sig, gpio in FW[esp].items():
        k = CORE.index(sig) + 1
        expect_same((esp, devkit_pad(gpio)), (core, str(k)), f"{esp} {gpio} -> {core} {sig}")
        rows.append(f"{esp} {gpio:7s} -> {core} {sig}")
    expect_same((esp, "1"), (core, "8"), f"{esp} 3V3 -> {core} 3V3")
    for k in (2, 7, 10):
        if net_of(core, str(k)) != "GND":
            errors.append(f"{core} pad {k} not GND")
    if net_of(core, "6") not in ("",):
        errors.append(f"{core} NC pad connected to {net_of(core, '6')}")
    for k in ("22", "23", "43", "44"):
        if net_of(esp, k) != "GND":
            errors.append(f"{esp} pad {k} ({pin_name(esp, k)}) not GND")
# UART: Pi TX -> resistor -> ESP RX (GPIO1), ESP TX (GPIO2) -> resistor -> Pi RX
expect_via(("U5", "7"), ("U1", devkit_pad("GPIO1")), "R5", "Pi UART4 TX -> ESP32 A RX")
expect_via(("U1", devkit_pad("GPIO2")), ("U5", "16"), "R6", "ESP32 A TX -> Pi UART4 RX")
expect_via(("U5", "28"), ("U2", devkit_pad("GPIO1")), "R7", "Pi UART3 TX -> ESP32 B RX")
expect_via(("U2", devkit_pad("GPIO2")), ("U5", "27"), "R8", "ESP32 B TX -> Pi UART3 RX")
expect_via(("U5", "8"), ("J3", "2"), "R9", "Pi UART0 TX -> console pin 2 (adapter RXD)")
expect_via(("J3", "3"), ("U5", "10"), "R10", "console pin 3 (adapter TXD) -> Pi UART0 RX")
expect_same(("J2", "3"), ("U5", "13"), "GPS TX -> Pi UART5 RX")
expect_same(("J2", "4"), ("U5", "11"), "Pi UART5 TX -> GPS RX")
expect_same(("J2", "5"), ("U5", "15"), "GPS PPS -> Pi PI5")
expect_same(("J2", "1"), ("U5", "1"), "GPS 3V3")
# I2C: all sockets on Pi pin 3 (SDA) / 5 (SCL) / 3V3 / GND
for ref in ("J6", "J7", "J8", "J9", "J10", "J11", "J17", "J18", "J19", "J20"):
    expect_same((ref, "1"), ("U5", "6"), f"{ref} GND")
    expect_same((ref, "2"), ("U5", "1"), f"{ref} 3V3")
    expect_same((ref, "3"), ("U5", "3"), f"{ref} SDA")
    expect_same((ref, "4"), ("U5", "5"), f"{ref} SCL")
for ref in ("J4", "J12"):
    expect_same((ref, "1"), ("U5", "6"), f"{ref} GND")
    expect_same((ref, "2"), ("U5", "1"), f"{ref} 3V3")
    expect_same((ref, "3"), ("U5", "5"), f"{ref} SCL")
    expect_same((ref, "4"), ("U5", "3"), f"{ref} SDA")
for r in ("R19", "R20"):
    if net_of(r, "1") != net_of("U5", "1") or net_of(r, "2") not in (net_of("U5", "3"), net_of("U5", "5")):
        errors.append(f"{r} is not an I2C pull-up")
# power
for p in ("2", "4"):
    expect_same(("U5", p), ("F1", "2"), f"Pi pin {p} 5V")
for p in ("6", "9", "14", "20", "25", "30", "34", "39"):
    if net_of("U5", p) != "GND":
        errors.append(f"Pi pin {p} not GND")
for esp, d in (("U1", "D2"), ("U2", "D3")):
    expect_same((d, "2"), ("F1", "2"), f"{d} anode on 5 V")
    expect_same((d, "1"), (esp, "21"), f"{d} cathode -> {esp} 5V")
if net_of("U1", "1") == net_of("U2", "1"):
    errors.append("3V3 of both ESP32 connected together")
if net_of("U1", "1") == net_of("U5", "1"):
    errors.append("ESP32 3V3 connected to Pi 3V3")
# ESP reset / boot: Pi pin -> 1k -> gate, drain -> EN / GPIO0, source GND, 100k gate pull-down
for esp, pin_en, pin_io0, (qe, qi), (re_, ri), (pe, pi_) in (
        ("U1", "29", "31", ("Q3", "Q4"), ("R11", "R12"), ("R15", "R16")),
        ("U2", "32", "33", ("Q5", "Q6"), ("R13", "R14"), ("R17", "R18"))):
    for pin, q, r, pd, target in ((pin_en, qe, re_, pe, "RST"), (pin_io0, qi, ri, pi_, "GPIO0")):
        expect_via(("U5", pin), (q, "1"), r, f"Pi pin {pin} -> {r} -> {q} gate")
        expect_same((q, "3"), (esp, devkit_pad(target)), f"{q} drain -> {esp} {target}")
        if net_of(q, "2") != "GND" or net_of(pd, "2") != "GND" or net_of(pd, "1") != net_of(q, "1"):
            errors.append(f"{q}: source / pull-down wrong")
# antennas: module pad -> series 0R -> SMA centre pin, SMA body = GND
for core, k, sma in (("U3", "9", "J13"), ("U3", "1", "J14"), ("U4", "1", "J15"), ("U4", "9", "J16")):
    nm, ns = net_of(core, k), net_of(sma, "1")
    rs = [r for r in ("R21", "R22", "R23", "R24") if {net_of(r, "1"), net_of(r, "2")} == {nm, ns}]
    if len(rs) != 1:
        errors.append(f"{core} {CORE[int(k) - 1]} -> {sma}: no series part")
    if net_of(sma, "2") != "GND":
        errors.append(f"{sma} body not GND")

print("connections checked against the pin names:")
for r in rows:
    print("  ", r)
print("errors:", len(errors))
for e in errors:
    print("  !!", e)

# ---- track length per net ---------------------------------------------------------------------------
tracks = [t for t in board.GetTracks() if t.GetClass() == "PCB_TRACK"]
length = {}
for t in tracks:
    length[t.GetNetname()] = length.get(t.GetNetname(), 0.0) + mm(t.GetLength())


def mst(points):
    """Length of the minimum spanning tree (Manhattan-free, straight) = shortest possible copper."""
    if len(points) < 2:
        return 0.0
    done, rest, total = [points[0]], points[1:], 0.0
    while rest:
        d, k = min((min(math.dist(a, b) for a in done), k) for k, b in enumerate(rest))
        total += d
        done.append(rest.pop(k))
    return total


report = []
for net in sorted(length):
    if net == "GND" or net.startswith("RF_"):
        continue
    pts = []
    for fp in board.GetFootprints():
        for p in fp.Pads():
            if p.GetNetname() == net:
                pts.append((mm(p.GetPosition().x), mm(p.GetPosition().y)))
    m = mst(pts)
    report.append((length[net] / m if m else 0, net, length[net], m))
report.sort(reverse=True)
print("\ntrack length / shortest possible (worst first):")
for ratio, net, L, m in report[:15]:
    print(f"   {net:10s} {L:6.1f} mm  (min {m:5.1f} mm)  x{ratio:.2f}")
print(f"   total signal copper {sum(r[2] for r in report):.0f} mm, {len(report)} nets")
vias = [t for t in board.GetTracks() if t.GetClass() == "PCB_VIA"]
print("vias:", len(vias), "of which signal vias:", sum(1 for v in vias if v.GetNetname() != "GND"))
bottom = sum(mm(t.GetLength()) for t in tracks if t.GetLayer() == pcbnew.B_Cu and t.GetNetname() != "GND")
print(f"signal copper on the bottom layer: {bottom:.0f} mm")

# ---- spacing between parts ------------------------------------------------------------------------
boxes = []
for fp in board.GetFootprints():
    c = fp.GetCourtyard(pcbnew.F_CrtYd)
    for k in range(c.OutlineCount()):        # each outline separately (radio sockets: one per pin row)
        bb = c.Outline(k).BBox()
        boxes.append((fp.GetReference(), mm(bb.GetLeft()), mm(bb.GetTop()), mm(bb.GetRight()), mm(bb.GetBottom())))
close = []
for a, b in itertools.combinations(boxes, 2):
    if a[0] == b[0]:
        continue
    dx = max(a[1] - b[3], b[1] - a[3], 0)
    dy = max(a[2] - b[4], b[2] - a[4], 0)
    d = math.hypot(dx, dy)
    if d < 0.25:
        close.append((d, a[0], b[0]))
print("\nparts closer than 0.25 mm (outline to outline):", len(close))
for d, a, b in sorted(close):
    print(f"   {a}-{b}: {d:.2f} mm")
sys.exit(1 if errors else 0)
