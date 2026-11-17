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
# USB console: USB-C -> ESD -> CH340C, CH340C TXD -> 4.7k -> Pi RX0, Pi TX0 -> 1k -> CH340C RXD
for a, b, what in ((("J21", "A6"), ("U6", "5"), "USB D+ (A6) -> CH340C UD+"), (("J21", "B6"), ("U6", "5"), "USB D+ (B6)"),
                   (("J21", "A7"), ("U6", "6"), "USB D- (A7) -> CH340C UD-"), (("J21", "B7"), ("U6", "6"), "USB D- (B7)"),
                   (("U7", "1"), ("U6", "5"), "ESD I/O1 on D+"), (("U7", "3"), ("U6", "6"), "ESD I/O2 on D-"),
                   (("U7", "5"), ("J21", "A4"), "ESD VBUS"), (("U6", "16"), ("U5", "1"), "CH340C VCC = 3.3 V"),
                   (("U6", "4"), ("U5", "1"), "CH340C V3 = VCC (3.3 V mode)")):
    expect_same(a, b, what)
for p in (("U6", "1"), ("U7", "2"), ("J21", "A1"), ("J21", "B12")):
    if net_of(*p) != "GND":
        errors.append(f"{p} not GND")
expect_via(("U6", "2"), ("U5", "10"), "R28", "CH340C TXD -> Pi UART0 RX")
expect_via(("U5", "8"), ("U6", "3"), "R27", "Pi UART0 TX -> CH340C RXD")
if net_of("J21", "A4") in (net_of("F1", "2"), net_of("U5", "1")):
    errors.append("USB VBUS connected to a node supply")
# I2C: all sockets on Pi pin 3 (SDA) / 5 (SCL) / 3V3 / GND
for ref in ("J6", "J7", "J8", "J9", "J10", "J11", "J17", "J18", "J19", "J20"):
    expect_same((ref, "1"), ("U5", "9"), f"{ref} GND")
    expect_same((ref, "2"), ("U5", "1"), f"{ref} 3V3")
    expect_same((ref, "3"), ("U5", "3"), f"{ref} SDA")
    expect_same((ref, "4"), ("U5", "5"), f"{ref} SCL")
for ref in ("J4", "J12"):
    expect_same((ref, "1"), ("U5", "9"), f"{ref} GND")
    expect_same((ref, "2"), ("U5", "1"), f"{ref} 3V3")
    expect_same((ref, "3"), ("U5", "5"), f"{ref} SCL")
    expect_same((ref, "4"), ("U5", "3"), f"{ref} SDA")
for r in ("R19", "R20"):
    if net_of(r, "1") != net_of("U5", "1") or net_of(r, "2") not in (net_of("U5", "3"), net_of("U5", "5")):
        errors.append(f"{r} is not an I2C pull-up")
# power
for p in ("2", "4"):
    expect_same(("U5", p), ("F1", "2"), f"Pi pin {p} 5V")
for p in ("9", "14", "20", "25", "30", "34", "39"):      # pin 6 is only connected inside the Pi
    if net_of("U5", p) != "GND":
        errors.append(f"Pi pin {p} not GND")
for esp, d in (("U1", "D2"), ("U2", "D3")):
    expect_same((d, "2"), ("F1", "2"), f"{d} anode on 5 V")
    expect_same((d, "1"), (esp, "21"), f"{d} cathode -> {esp} 5V")
if net_of("U1", "1") == net_of("U2", "1"):
    errors.append("3V3 of both ESP32 connected together")
if net_of("U1", "1") == net_of("U5", "1"):
    errors.append("ESP32 3V3 connected to Pi 3V3")
# ESP reset / boot: Pi pin -> 1k -> gate, drain -> EN / GPIO0, source GND, 10k gate pull-down
for esp, pin_en, pin_io0, (qe, qi), (re_, ri), (pe, pi_) in (
        ("U1", "29", "31", ("Q3", "Q4"), ("R11", "R12"), ("R15", "R16")),
        ("U2", "32", "33", ("Q5", "Q6"), ("R13", "R14"), ("R17", "R18"))):
    for pin, q, r, pd, target in ((pin_en, qe, re_, pe, "RST"), (pin_io0, qi, ri, pi_, "GPIO0")):
        expect_via(("U5", pin), (q, "1"), r, f"Pi pin {pin} -> {r} -> {q} gate")
        expect_same((q, "3"), (esp, devkit_pad(target)), f"{q} drain -> {esp} {target}")
        if net_of(q, "2") != "GND" or net_of(pd, "2") != "GND" or net_of(pd, "1") != net_of(q, "1"):
            errors.append(f"{q}: source / pull-down wrong")
# 868 MHz front end, Skyworks SE2435L (pin names from the data sheet, Table 1) and its LDO TLV75901 (DRV)
SE = {1: "CSD", 2: "PA_IN", 3: "CPS", 4: "CTX", 5: "TX_FLT", 6: "TR", 7: "ANT_SEL", 8: "GND", 9: "LNA_IN",
      10: "NC", 11: "RX_FLT", 12: "ANT2", 13: "NC", 14: "ANT1", 15: "NC", 16: "TX_IN", 17: "NC", 18: "NC",
      19: "NC", 20: "PA_OUT", 21: "VCC2", 22: "NC", 23: "VCC0", 24: "VCC1", 25: "PAD"}
LDO = {1: "OUT", 2: "FB", 3: "GND", 4: "EN", 5: "PG", 6: "IN", 7: "PAD"}
SEp = {v: str(k) for k, v in SE.items() if v != "NC"}
FW_FE = {"CSD": "GPIO42", "CPS": "GPIO41", "CTX": "GPIO40"}       # firmware/lr2021_modem/config.h, role A


def shunt(node, part, what):
    """part between the net of `node` and GND."""
    if {net_of(part, "1"), net_of(part, "2")} != {net_of(*node), "GND"}:
        errors.append(f"{what}: {part} is not a shunt from {net_of(*node)} to GND")


def series(a, b, part, what):
    expect_via(a, b, part, what)


expect_same(("U3", "9"), ("J22", "4"), "Core2021-HF LORA_ANT -> filter socket pin 4")
expect_same(("J22", "2"), ("U8", SEp["TR"]), "filter socket pin 2 -> SE2435L TR")
for k in ("1", "3", "5"):
    if net_of("J22", k) != "GND":
        errors.append(f"filter socket pin {k} not GND")
series(("U8", SEp["TX_FLT"]), ("U8", SEp["PA_IN"]), "C35", "SE2435L TX_FLT -> 3.3 pF -> PA_IN")
series(("U8", SEp["RX_FLT"]), ("U8", SEp["LNA_IN"]), "R33", "SE2435L RX_FLT -> 0R -> LNA_IN")
for name in ("ANT_SEL", "GND", "PAD"):
    if net_of("U8", SEp[name]) != "GND":
        errors.append(f"SE2435L {name} not GND")
for k in ("10", "12", "19", "22"):          # not connected / do not connect
    if net_of("U8", k) != "":
        errors.append(f"SE2435L pin {k} ({SE[int(k)]}) connected to {net_of('U8', k)}")
# PA output match (EK5): PA_OUT - L2 - N1 (C30, C31 to GND) - L1 - TX_IN, trap L7 + C32 at TX_IN
series(("U8", SEp["PA_OUT"]), ("L1", "2"), "L2", "PA_OUT -> L2 -> N1")
series(("L2", "2"), ("U8", SEp["TX_IN"]), "L1", "N1 -> L1 -> TX_IN")
shunt(("L2", "2"), "C30", "N1 10 pF")
shunt(("L2", "2"), "C31", "N1 5 pF")
series(("U8", SEp["TX_IN"]), ("C32", "1"), "L7", "TX_IN trap L7")
shunt(("L7", "2"), "C32", "TX_IN trap C32")
# antenna low-pass: ANT1 - L8 - N3 (trap L9 + C33) - L6 - N4 (C9 to GND) - R21 - SMA
series(("U8", SEp["ANT1"]), ("L6", "1"), "L8", "ANT1 -> L8 -> N3")
series(("L8", "2"), ("R21", "1"), "L6", "N3 -> L6 -> N4")
series(("L8", "2"), ("C33", "2"), "L9", "N3 trap L9")
shunt(("L9", "1"), "C33", "N3 trap C33")
shunt(("L6", "2"), "C9", "N4 2.7 pF")
series(("L6", "2"), ("J13", "1"), "R21", "N4 -> R21 -> SMA 868")
# supplies
for pin, ind in (("VCC2", "L5"), ("VCC0", "L3"), ("VCC1", "L4")):
    series(("U8", SEp[pin]), ("U9", "1"), ind, f"{pin} feed {ind}")
shunt(("U8", SEp["VCC0"]), "C26", "VCC0 22 pF")
shunt(("U8", SEp["VCC1"]), "C27", "VCC1 100 pF")
shunt(("U8", SEp["VCC1"]), "C28", "VCC1 47 pF")
for c in ("C21", "C22", "C23", "C24", "C25"):
    shunt(("U9", "1"), c, f"PA supply {c}")
expect_same(("U9", "6"), ("U9", "4"), "LDO EN = IN (always on)")
series(("F1", "2"), ("U9", "6"), "FB1", "5 V -> ferrite -> LDO IN")
shunt(("U9", "6"), "C20", "LDO input capacitor")
series(("U9", "1"), ("U9", "2"), "R31", "LDO OUT -> R31 -> FB")
shunt(("U9", "2"), "R32", "LDO FB -> R32 -> GND")
for k in ("3", "7"):
    if net_of("U9", k) != "GND":
        errors.append(f"TLV75901 {LDO[int(k)]} not GND")
_val = {fp.GetReference(): fp.GetValue() for fp in board.GetFootprints()}
_r = lambda s: float(s.lower().replace("k", "e3"))
vpa = 0.55 * (1 + _r(_val["R31"]) / _r(_val["R32"]))
if not 4.0 <= vpa <= 4.8:
    errors.append(f"PA supply {vpa:.2f} V outside 4.0-4.8 V (SE2435L recommended range)")
rows.append(f"PA supply 0.55 V x (1 + {_val['R31']}/{_val['R32']}) = {vpa:.2f} V")
# control lines ESP32 A -> 1k -> SE2435L, pull-down on CSD
for sig, r in (("CSD", "R34"), ("CPS", "R35"), ("CTX", "R36")):
    series(("U1", devkit_pad(FW_FE[sig])), ("U8", SEp[sig]), r, f"ESP32 A {FW_FE[sig]} -> {r} -> SE2435L {sig}")
    rows.append(f"U1 {FW_FE[sig]:7s} -> {r} -> U8 {sig}")
shunt(("U1", devkit_pad(FW_FE["CSD"])), "R37", "CSD pull-down")
# antennas: module pad -> series 0R -> SMA centre pin, SMA body = GND (868 MHz: through the front end, above)
for core, k, sma in (("U3", "1", "J14"), ("U4", "1", "J15"), ("U4", "9", "J16")):
    nm, ns = net_of(core, k), net_of(sma, "1")
    rs = [r for r in ("R21", "R22", "R23", "R24") if {net_of(r, "1"), net_of(r, "2")} == {nm, ns}]
    if len(rs) != 1:
        errors.append(f"{core} {CORE[int(k) - 1]} -> {sma}: no series part")
    if net_of(sma, "2") != "GND":
        errors.append(f"{sma} body not GND")

if net_of("J13", "2") != "GND":
    errors.append("J13 body not GND")
# ESD shunt inductor at every antenna connector (centre pin -> L -> GND)
for sma, ind in (("J13", "L10"), ("J14", "L11"), ("J15", "L12"), ("J16", "L13")):
    shunt((sma, "1"), ind, f"ESD inductor at {sma}")
# polarity (KiCad diode/LED footprints: pad 1 = cathode; SOT-23 MOSFET: 1 = G, 2 = S, 3 = D)
v5 = net_of("F1", "2")
if net_of("D1", "1") != v5 or net_of("D1", "2") != "GND":
    errors.append("TVS D1: cathode must be on 5 V, anode on GND")
if net_of("D4", "1") != "GND" or net_of("R4", "1") != v5 or net_of("R4", "2") != net_of("D4", "2"):
    errors.append("power LED D4: 5 V -> R4 -> anode, cathode GND")
for led, r, sig in (("D5", "R29", ("U6", "2")), ("D6", "R30", ("U5", "8"))):
    if net_of(led, "2") != net_of("U5", "1") or net_of(r, "1") != net_of(led, "1") or net_of(r, "2") != net_of(*sig):
        errors.append(f"{led}: 3.3 V -> anode, cathode -> {r} -> {sig}")
for q in ("Q1", "Q2"):            # reverse-polarity P-MOSFETs: drain = input, source = output, gate pulled to GND
    if net_of(q, "3") != net_of("J1", "1") or net_of(q, "2") != net_of("F1", "1") or net_of(q, "1") != net_of("R3", "1") \
            or net_of("R3", "2") != "GND":
        errors.append(f"{q}: drain/source/gate of the reverse-polarity protection wrong")
expect_same(("J1", "1"), ("J5", "A9"), "J1 + and USB-C VBUS on the same input")
for cc, r in (("A5", "R1"), ("B5", "R2")):
    if net_of(r, "1") != net_of("J5", cc) or net_of(r, "2") != "GND":
        errors.append(f"USB-C power {cc}: 5.1k to GND missing")
if net_of("J1", "2") != "GND":
    errors.append("J1 pin 2 not GND")
series(("F1", "1"), ("F1", "2"), "F1", "fuse between protected input and 5 V")

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
# Courtyards already include a margin of 0.25 mm around the body. Small passives and the chips of the
# 868 MHz front end may touch courtyards (>= 0.5 mm between the bodies, short RF connections);
# all other parts keep 0.25 mm between their courtyards.
SMALL = ("C_0402", "R_0402", "L_0402", "C_0603", "R_0603", "L_0603", "C_0805", "QFN-24", "WSON-6")
boxes = []
for fp in board.GetFootprints():
    c = fp.GetCourtyard(pcbnew.F_CrtYd)
    small = fp.GetFPID().GetLibItemName().wx_str().startswith(SMALL)
    for k in range(c.OutlineCount()):        # each outline separately (radio sockets: one per pin row)
        bb = c.Outline(k).BBox()
        boxes.append((fp.GetReference(), mm(bb.GetLeft()), mm(bb.GetTop()), mm(bb.GetRight()), mm(bb.GetBottom()), small))
close = []
for a, b in itertools.combinations(boxes, 2):
    if a[0] == b[0]:
        continue
    dx = max(a[1] - b[3], b[1] - a[3], 0)
    dy = max(a[2] - b[4], b[2] - a[4], 0)
    d = math.hypot(dx, dy)
    overlap = dx == 0 and dy == 0 and min(a[3], b[3]) - max(a[1], b[1]) > 1e-3 and min(a[4], b[4]) - max(a[2], b[2]) > 1e-3
    if overlap or (d < 0.25 and not (a[5] and b[5])):
        close.append((d, a[0], b[0]))
print("\nparts too close (courtyards overlap; or < 0.25 mm apart unless both are small passives/RF chips):",
      len(close))
for d, a, b in sorted(close):
    print(f"   {a}-{b}: {d:.2f} mm")

# ---- copper of different nets touching or closer than 0.15 mm (independent of the KiCad DRC) ----------
import collections
items = []
for L in (pcbnew.F_Cu, pcbnew.B_Cu):
    for t in board.GetTracks():
        if t.IsOnLayer(L):
            items.append((L, t.GetNetCode(), t.GetBoundingBox(), t.GetEffectiveShape(L), t.GetNetname(), False))
    for fp in board.GetFootprints():
        for p in fp.Pads():
            if p.IsOnLayer(L) and p.GetAttribute() != pcbnew.PAD_ATTRIB_NPTH:
                items.append((L, p.GetNetCode(), p.GetBoundingBox(), p.GetEffectiveShape(L),
                              f"{fp.GetReference()}.{p.GetNumber()} {p.GetNetname()}", False))
    for z in board.Zones():
        if z.IsOnLayer(L):
            polys = z.GetFilledPolysList(L)
            for k in range(polys.OutlineCount()):
                sp = pcbnew.SHAPE_POLY_SET(polys.Outline(k))
                items.append((L, z.GetNetCode(), sp.BBox(), sp, "plane " + z.GetNetname(), True))
grid = collections.defaultdict(list)
cell = pcbnew.FromMM(2.0)
for k, it in enumerate(items):
    if it[5]:
        continue
    bb = it[2]
    for i in range(bb.GetLeft() // cell - 1, bb.GetRight() // cell + 2):
        for j in range(bb.GetTop() // cell - 1, bb.GetBottom() // cell + 2):
            grid[(it[0], i, j)].append(k)
pairs = set()
for ks in grid.values():
    for a_, b_ in itertools.combinations(ks, 2):
        pairs.add((min(a_, b_), max(a_, b_)))
for zk, z in enumerate(items):
    if z[5]:
        for k, it in enumerate(items):
            if not it[5] and it[0] == z[0] and z[2].Intersects(it[2]):
                pairs.add((zk, k))
copper_err = []
for a_, b_ in pairs:
    A, Bq = items[a_], items[b_]
    if A[1] == Bq[1] or (A[1] == 0 and Bq[1] == 0):
        continue
    if A[3].Collide(Bq[3], pcbnew.FromMM(0.149)):
        what = "SHORT" if A[3].Collide(Bq[3], 0) else "gap < 0.15 mm"
        copper_err.append(f"{what}: {A[4]} / {Bq[4]} ({'top' if A[0] == pcbnew.F_Cu else 'bottom'})")
print(f"\ncopper of different nets touching or closer than 0.15 mm: {len(copper_err)} ({len(items)} copper items)")
for e in copper_err:
    print("   !!", e)
errors += copper_err
sys.exit(1 if errors else 0)
