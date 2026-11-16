#!/usr/bin/env python3
"""LR2021 Node carrier board – generator.

Builds the KiCad PCB (placement, nets, routing, ground planes) from the definitions in this file and
writes lr2021-carrier.kicad_pcb. Run inside an environment with KiCad 9 (pcbnew Python module),
numpy, scipy and gcc:

    python3 generate_board.py

Afterwards `make_outputs.py` runs the design rule check and writes Gerber, drill, BOM and placement
files for ordering; `check_board.py` checks the connections against the pin names of the modules.
"""
import json
import math
import os
import sys

import numpy as np
import pcbnew
from scipy import ndimage

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "lr2021-carrier.kicad_pcb")
LIB = "/usr/share/kicad/footprints"

VERSION = "1.3"
BOARD_W, BOARD_H = 172.0, 106.0

MM = pcbnew.FromMM


def V(x, y):
    return pcbnew.VECTOR2I(MM(x), MM(y))


board = pcbnew.BOARD()
board.SetCopperLayerCount(2)
ds = board.GetDesignSettings()
ds.m_TrackMinWidth = MM(0.127)   # 0.127 mm only for two control lines under C35
ds.m_ViasMinSize = MM(0.6)
ds.m_MinThroughDrill = MM(0.3)
ds.m_CopperEdgeClearance = MM(0.4)
ds.m_HoleToHoleMin = MM(0.5)
ds.m_HoleClearance = MM(0.25)
ds.m_MinClearance = MM(0.15)
ds.m_NetSettings.GetDefaultNetclass().SetClearance(MM(0.15))
ds.m_NetSettings.GetDefaultNetclass().SetTrackWidth(MM(0.25))
ds.SetAuxOrigin(V(0, BOARD_H))  # placement origin = lower left corner
ds.m_TentViasFront = True        # vias covered by solder mask (also keeps the silkscreen intact)
ds.m_TentViasBack = True

nets = {}


def net(name):
    if name not in nets:
        n = pcbnew.NETINFO_ITEM(board, name)
        board.Add(n)
        nets[name] = n
    return nets[name]


# ----------------------------------------------------------------------------------------------
# Footprints
# ----------------------------------------------------------------------------------------------
def silk_line(fp, x1, y1, x2, y2, layer=pcbnew.F_SilkS, w=0.15):
    s = pcbnew.PCB_SHAPE(fp)
    s.SetShape(pcbnew.SHAPE_T_SEGMENT)
    s.SetStart(V(x1, y1))
    s.SetEnd(V(x2, y2))
    s.SetLayer(layer)
    s.SetWidth(MM(w))
    fp.Add(s)


def silk_rect(fp, x1, y1, x2, y2, layer=pcbnew.F_SilkS, w=0.15):
    for a, b, c, d in ((x1, y1, x2, y1), (x2, y1, x2, y2), (x2, y2, x1, y2), (x1, y2, x1, y1)):
        silk_line(fp, a, b, c, d, layer, w)


def fp_text(fp, text, x, y, size=1.0, layer=pcbnew.F_SilkS, angle=0, thick=0.15):
    t = pcbnew.PCB_TEXT(fp)
    t.SetText(text)
    t.SetPosition(V(x, y))
    t.SetLayer(layer)
    t.SetTextSize(V(size, size))
    t.SetTextThickness(MM(thick))
    if angle:
        t.SetTextAngleDegrees(angle)
    fp.Add(t)


def board_text(text, x, y, size=1.0, layer=pcbnew.F_SilkS, angle=0, thick=0.15):
    t = pcbnew.PCB_TEXT(board)
    t.SetText(text)
    t.SetPosition(V(x, y))
    t.SetLayer(layer)
    t.SetTextSize(V(size, size))
    t.SetTextThickness(MM(thick))
    if angle:
        t.SetTextAngleDegrees(angle)
    if layer == pcbnew.B_SilkS:
        t.SetMirrored(True)
    board.Add(t)


def tht_pad(fp, num, x, y, size=1.7, drill=1.0, square=False):
    p = pcbnew.PAD(fp)
    p.SetNumber(str(num))
    p.SetAttribute(pcbnew.PAD_ATTRIB_PTH)
    p.SetShape(pcbnew.PAD_SHAPE_RECT if square else pcbnew.PAD_SHAPE_CIRCLE)
    p.SetSize(V(size, size))
    p.SetDrillSize(V(drill, drill))
    p.SetLayerSet(pcbnew.PAD.PTHMask())
    p.SetPosition(V(x, y))
    fp.Add(p)
    return p


def npth(fp, x, y, d):
    p = pcbnew.PAD(fp)
    p.SetNumber("")
    p.SetAttribute(pcbnew.PAD_ATTRIB_NPTH)
    p.SetShape(pcbnew.PAD_SHAPE_CIRCLE)
    p.SetSize(V(d, d))
    p.SetDrillSize(V(d, d))
    p.SetLayerSet(pcbnew.PAD.UnplatedHoleMask())
    p.SetPosition(V(x, y))
    fp.Add(p)


def new_fp(ref, value, name):
    fp = pcbnew.FOOTPRINT(board)
    fp.SetFPID(pcbnew.LIB_ID("LR2021", name))
    fp.SetReference(ref)
    fp.SetValue(value)
    fp.Reference().SetVisible(False)
    fp.Value().SetVisible(False)
    fp.Reference().SetLayer(pcbnew.F_SilkS)
    fp.Value().SetLayer(pcbnew.F_Fab)
    return fp


def devkit_socket(ref, label):
    """ESP32-S3-DevKitC-1 seen from above, USB connectors at the top.

    Local origin = J1 pin 1 (3V3). J1 is the right row, its pins go upwards. The left row (J3) has two
    alternative positions: 22.86 mm (Espressif original) and 25.40 mm (many N16R8 boards); both are
    connected, the socket is soldered into the row that matches the board.
    Pads 1–22 = J1 pin 1–22, pads 23–44 = J3 pin 1–22.
    """
    fp = new_fp(ref, "ESP32-S3-DevKitC-1", "ESP32-S3-DevKitC-1_Socket")
    for n in range(22):
        y = -n * 2.54
        tht_pad(fp, n + 1, 0, y, square=(n == 0))
        tht_pad(fp, 23 + n, -22.86, y, square=(n == 0))
        tht_pad(fp, 23 + n, -25.40, y, square=(n == 0))
    top = -21 * 2.54 - 8.0   # USB end
    bot = 1.40
    silk_rect(fp, -25.4 - 1.6, top, 1.6, bot + 0.3)
    # courtyard = the pin rows (small parts may sit under the board, it is 8.5 mm above the carrier)
    silk_rect(fp, -1.3, -21 * 2.54 - 1.3, 1.3, 1.3, layer=pcbnew.F_CrtYd, w=0.05)
    silk_rect(fp, -25.4 - 1.3, -21 * 2.54 - 1.3, -22.86 + 1.3, 1.3, layer=pcbnew.F_CrtYd, w=0.05)
    silk_line(fp, -22.86 - 1.3, top + 3.5, -22.86 - 1.3, bot - 1, w=0.1)
    fp_text(fp, label, -11.43, -30.0, 1.4, angle=90)
    fp_text(fp, "USB", -11.43, top + 2.5, 1.0)
    fp_text(fp, "J1 3V3", -3.6, 0.0, 0.8)
    fp_text(fp, "5V", -1.9, -20 * 2.54, 0.8)
    fp_text(fp, "25.4", -25.4, bot + 1.4, 0.8)
    fp_text(fp, "22.86", -22.0, bot + 1.4, 0.8)
    return fp


CORE_NAMES = ["2.4G_ANT", "GND", "DIO11", "DIO8", "DIO7", "NC", "GND", "3V3",
              "LORA_ANT", "GND", "CS", "CLK", "MOSI", "MISO", "RESET", "BUSY"]


def core_socket(ref, value):
    """Waveshare Core2021-HF/-LF (19 x 22 mm, 2 x 8 pins, rows 15.24 mm apart).

    Local frame = module seen from above as in the Waveshare drawing: antenna end (IPEX) on the
    right, 2.4 GHz row on top. Pads 1–8 = top row from the antenna end (2.4G_ANT … 3V3),
    pads 9–16 = bottom row from the antenna end (LORA_ANT … BUSY). Origin = module centre.
    """
    fp = new_fp(ref, value, "Core2021_Socket")
    for k in range(8):
        x = 8.89 - k * 2.54
        tht_pad(fp, k + 1, x, -7.62, square=(k == 0))
        tht_pad(fp, k + 9, x, 7.62, square=(k == 0))
    # module outline as corner marks only (the RF lines leave the socket across the outline)
    for sx in (-1,):          # no marks at the antenna end, the RF lines leave the socket there
        for sy in (-1, 1):
            silk_line(fp, sx * 11.0, sy * 9.225, sx * 10.2, sy * 9.225)
            silk_line(fp, sx * 11.0, sy * 9.225, sx * 11.0, sy * 8.625)
    # courtyard = the two pin rows (small parts may sit under the module, it is 8.5 mm above the board)
    for sy in (-1, 1):
        silk_rect(fp, -11.0, sy * 6.0, 11.0, sy * 9.225, layer=pcbnew.F_CrtYd, w=0.05)
    fp_text(fp, value, -1.5, 0.0, 1.2)
    fp_text(fp, "ANT", 8.6, -2.3, 0.8)
    fp_text(fp, "2.4G", 8.6, -4.6, 0.8)
    fp_text(fp, "LoRa", 8.6, 4.6, 0.8)
    return fp


def pi_socket(ref):
    """Orange Pi Zero 2W, component side up, 2 x 20 header soldered underneath.

    Local origin = top left corner of the Pi (micro SD end left, header along the top edge,
    ports along the bottom edge). Pin 1 inner row, pin 2 outer row.
    """
    fp = new_fp(ref, "Orange Pi Zero 2W", "OrangePi_Zero2W_Socket")
    x0 = 32.5 - 9.5 * 2.54
    for n in range(1, 41):
        col = (n - 1) // 2
        x = x0 + col * 2.54
        y = 4.77 if n % 2 else 2.23
        tht_pad(fp, n, x, y, square=(n == 1))
    for hx, hy in ((3.5, 3.5), (61.5, 3.5), (3.5, 26.5), (61.5, 26.5)):
        npth(fp, hx, hy, 2.75)
    silk_rect(fp, 0, 0, 65.0, 30.0)
    silk_rect(fp, 0, 0, 65.0, 30.0, layer=pcbnew.F_CrtYd, w=0.05)
    fp_text(fp, "Orange Pi Zero 2W", 32.5, 13.0, 1.5)
    fp_text(fp, "ports on this edge", 32.5, 27.5, 1.0)
    fp_text(fp, "1", x0 - 1.9, 4.77, 0.9)
    fp_text(fp, "2", x0 - 1.9, 2.23, 0.9)
    fp_text(fp, "SD", 1.6, 13.0, 0.9, angle=90)
    return fp


def lib_fp(ref, value, lib, name):
    fp = pcbnew.FootprintLoad(os.path.join(LIB, lib + ".pretty"), name)
    fp.SetReference(ref)
    fp.SetValue(value)
    fp.Value().SetVisible(False)
    fp.Reference().SetTextSize(V(0.8, 0.8))
    if ref.startswith("J"):
        fp.Reference().SetVisible(False)
    fp.Reference().SetTextThickness(MM(0.12))
    return fp


def mount_hole(ref, x, y, m3=True):
    name = "MountingHole_3.2mm_M3" if m3 else "MountingHole_2.7mm_M2.5"
    fp = lib_fp(ref, "M3" if m3 else "M2.5", "MountingHole", name)
    fp.Reference().SetVisible(False)
    fp.SetPosition(V(x, y))
    board.Add(fp)
    return fp


# ----------------------------------------------------------------------------------------------
# Placement (mm, origin top left, y down)
# ----------------------------------------------------------------------------------------------
parts = {}   # ref -> (footprint, value, lcsc, assemble)


def place(fp, x, y, rot=0, value=None, lcsc="", assemble=True):
    fp.SetPosition(V(x, y))
    if rot:
        fp.SetOrientationDegrees(rot)
    board.Add(fp)
    parts[fp.GetReference()] = (fp, value or fp.GetValue(), lcsc, assemble)
    return fp


# ---- placement (carrier v1.2). Coordinates in mm, origin top left, y down. Antenna edge = top.
# The layout is mirror-symmetric about the vertical centre line wherever the parts allow it.
MID = BOARD_W / 2
X_DKA = 9.0                      # J1 pin column of ESP32 A (rotated 180 deg: USB at the bottom edge)
X_DKB = BOARD_W - X_DKA - 25.4   # J1 pin column of ESP32 B -> both outlines 7.4 mm from the side edges
Y_DK = BOARD_H - 61.64           # y of J1 pin 1 (3V3) of both DevKits
u1 = place(devkit_socket("U1", "ESP32 A (868 MHz)"), X_DKA, Y_DK, rot=180, assemble=False)
u2 = place(devkit_socket("U2", "ESP32 B (433 MHz)"), X_DKB, Y_DK, rot=180, assemble=False)
# both radio modules at the same height, mirrored about the centre line
CY_RF = 28.5
CX_HF, CX_LF = MID - 27.0, MID + 27.0
# Core2021-HF: antenna end down, LoRa row left, 2.4 GHz row right
CY_HF = CY_LF = CY_RF
u3 = place(core_socket("U3", "Core2021-HF"), CX_HF, CY_HF, rot=-90, assemble=False)
# Core2021-LF: antenna end up, 2.4 GHz row left, LoRa row right
u4 = place(core_socket("U4", "Core2021-LF"), CX_LF, CY_LF, rot=90, assemble=False)
# Orange Pi Zero 2W centred at the bottom edge, ports to the edge
PI_X, PI_Y = MID - 32.5, BOARD_H - 30.3
u5 = place(pi_socket("U5"), PI_X, PI_Y, assemble=False)


def pi_pin(n):
    """Board position of Orange Pi header pin n."""
    col = (n - 1) // 2
    return PI_X + 32.5 - 9.5 * 2.54 + col * 2.54, PI_Y + (4.77 if n % 2 else 2.23)


R0603 = ("Resistor_SMD", "R_0603_1608Metric")
C0603 = ("Capacitor_SMD", "C_0603_1608Metric")


def smd(ref, value, lib, x, y, rot=0, lcsc="", assemble=True):
    return place(lib_fp(ref, value, *lib), x, y, rot, value, lcsc, assemble)


# ---- antenna connectors (SMA, 90 deg, through hole) along the top edge ----
SMA = ("Connector_Coaxial", "SMA_BAT_Wireless_BWSMA-KWE-Z001")
SMA_Y = 4.1
ANT = {   # ref: (x, label)
    "J13": (CX_HF - 11.62, "868 LoRa"),
    "J14": (CX_HF + 11.62, "2.4G HF"),
    "J15": (CX_LF - 11.62, "2.4G LF"),
    "J16": (CX_LF + 11.62, "433 LoRa"),
}
for ref, (x, label) in ANT.items():
    place(lib_fp(ref, "SMA " + label, *SMA), x, SMA_Y, 0, "BWSMA-KWE-Z001", "C496551")

# RF lines (50 ohm grounded coplanar waveguide) as point lists from the module pin to the SMA pin.
# Each line has a pi network near the SMA: shunt (not fitted) - series 0 ohm - shunt (not fitted).
RF_W, RF_GAP = 1.55, 0.30
PI_SH_SMA, PI_SER, PI_SH_MOD = 9.4, 12.0, 14.6      # y of the pi-network parts (same for all four lines)
hf_bot = CY_HF + 8.89
lf_top = CY_LF - 8.89
RF_LINES = {
    # name: (points, side of the shunt parts)
    # 868 MHz: from the antenna output of the front end (U8, below) to the SMA
    "RF_HF_LORA": ([(CX_HF - 11.62, 15.0 - 0.537), (CX_HF - 11.62, SMA_Y)], +1),
    "RF_HF_24": ([(CX_HF + 7.62, hf_bot), (CX_HF + 10.12, hf_bot), (CX_HF + 11.62, hf_bot - 1.5),
                  (CX_HF + 11.62, SMA_Y)], +1),
    "RF_LF_24": ([(CX_LF - 7.62, lf_top), (CX_LF - 7.62, lf_top - 0.3), (CX_LF - 11.62, lf_top - 4.3),
                  (CX_LF - 11.62, SMA_Y)], -1),
    "RF_LF_LORA": ([(CX_LF + 7.62, lf_top), (CX_LF + 7.62, lf_top - 0.3), (CX_LF + 11.62, lf_top - 4.3),
                    (CX_LF + 11.62, SMA_Y)], +1),
}
PI_PARTS = {}   # line name -> (series ref, shunt module side ref, shunt sma side ref)
rser, csh = 21, 9
for name, (pts, side) in RF_LINES.items():
    top_need = PI_SER + 1.3 if name == "RF_HF_LORA" else PI_SH_MOD + 0.6
    xs = [a[0] for a, b in zip(pts, pts[1:]) if abs(a[0] - b[0]) < 1e-6 and min(a[1], b[1]) <= PI_SH_SMA - 0.6
          and max(a[1], b[1]) >= top_need]
    assert xs, name
    x = xs[0]
    rs, c1, c2 = f"R{rser}", f"C{csh}", f"C{csh + 1}"
    smd(rs, "0R", R0603, x, PI_SER, 90, "C21189")
    smd(c1, "DNP", C0603, x + side * 0.8, PI_SH_MOD, 0 if side > 0 else 180, assemble=False)
    smd(c2, "DNP", C0603, x + side * 0.8, PI_SH_SMA, 0 if side > 0 else 180, assemble=False)
    PI_PARTS[name] = (rs, c1, c2)
    rser += 1
    csh += 2


# ---- 868 MHz front end: Skyworks SE2435L (1 W PA, LNA with bypass, T/R switch) ----
# Sits between the Core2021-HF and the 868 MHz SMA. Output match, supply decoupling and harmonic
# filter follow the Skyworks SE2435L-EK5 evaluation board (+30 dBm, 868-930 MHz, ETSI/FCC).
# The plug-in filter (J22, 1x5 socket: GND, IN, GND, OUT, GND) sits between the radio module and the
# front end: behind the LNA when receiving (strong signals outside the band never reach the LR2021,
# the filter loss costs almost no sensitivity there) and in front of the PA when transmitting (drive
# level only, a few mW). Without a filter module, a short wire from pin 2 to pin 4 replaces it.
# ESP32 A controls the front end: GPIO42 = CSD (on), GPIO41 = CPS (LNA), GPIO40 = CTX (transmit).
# The 10k pull-down on CSD keeps it off (sleep) while the ESP32 starts; the firmware also uses it to
# detect the front end (the pin reads low with its internal pull-up).
FX, FY = CX_HF - 18.5, 15.0        # centre of U8; its antenna output lines up with the SMA (u = 6.88)
C0402 = ("Capacitor_SMD", "C_0402_1005Metric")
L0402 = ("Inductor_SMD", "L_0402_1005Metric")
L0603 = ("Inductor_SMD", "L_0603_1608Metric")
R0402 = ("Resistor_SMD", "R_0402_1005Metric")


def fe(ref, value, lib, u, v, rot=0, lcsc="", assemble=True):
    return smd(ref, value, lib, FX + u, FY + v, rot, lcsc, assemble)


fe("U8", "SE2435L-R", ("Package_DFN_QFN", "QFN-24-1EP_4x4mm_P0.5mm_EP2.7x2.7mm"), 0, 0, 0, "C4748685")
# Layout: PA output and supplies above the chip, antenna side to the right (straight up to the SMA),
# control lines and the TR port to the left, receive filter loop below. Parts keep their courtyards.
# PA output match (L2, C30, C31, L1) and harmonic trap at TX_IN (L7, C32)
fe("L2", "1.2nH", L0603, 2.75, -3.5, 0, "C882496")
fe("C30", "10pF", C0402, 3.537, -5.5, 90, "C85874")
fe("C31", "5pF", C0402, 4.65, -5.5, 90, "C1573")
fe("L1", "6.8nH", L0402, 3.6, -1.6, 90, "C84403")
fe("L7", "1.0nH", L0402, 5.1, -0.15, 0, "C97981")
fe("C32", "3.9pF", C0402, 5.45, -1.7, 90, "C76907")
# antenna side: low-pass with 2nd-harmonic trap (L8, L9 + C33, L6, C9 = shunt of the pi network)
fe("L8", "5.6nH", L0603, 4.3, 1.15, 0, "C441735")
fe("L9", "1.5nH", L0402, 5.087, 2.95, 90, "C113053")
fe("C33", "3.3pF", C0402, 5.087, 4.95, 90, "C76906")
fe("L6", "8.2nH", L0603, 6.88, 0.25, 90, "C98009")
# supply feeds: VCC2 (PA output stage) via L5, VCC0 via L3, VCC1 via L4, decoupled as on the EK5
fe("L5", "6.8nH", L0603, 0.4, -4.4, 90, "C882493")
fe("L3", "39nH", L0402, -0.9, -3.75, 90, "C113055")
fe("C26", "22pF", C0402, -2.1, -3.75, 90, "C1555")
fe("C27", "100pF", C0402, -3.4, -3.45, 90, "C1546")
fe("C28", "47pF", C0402, -4.5, -3.45, 90, "C1567")
fe("L4", "39nH", L0402, -5.6, -3.45, 90, "C113055")
fe("C22", "4.7uF", C0603, -2.15, -7.5, 90, "C19666")
fe("C23", "10nF", C0402, -0.85, -7.2, 90, "C15195")
fe("C25", "100pF", C0402, 0.2, -7.2, 90, "C1546")
fe("C24", "1nF", C0402, 1.25, -7.2, 90, "C1523")
# PA input coupling (TX_FLT -> PA_IN); CPS and CTX pass underneath it
fe("C35", "3.3pF", ("Capacitor_SMD", "C_0805_2012Metric"), -3.75, 0.0, 90, "C1811")
# receive filter loop of the SE2435L: bridged (the filter sits at J22 instead)
fe("R33", "0R", R0402, 0.25, 3.25, 0, "C17168")
# control lines from ESP32 A (1k series), pull-down on CSD
fe("R34", "1k", R0402, -6.8, -1.85, 0, "C11702")
fe("R35", "1k", R0402, -6.8, -0.75, 0, "C11702")
fe("R36", "1k", R0402, -6.8, 0.75, 0, "C11702")
fe("R37", "10k", R0402, -7.31, -3.5, 90, "C25744")
# 4.7 V supply of the front end (TLV75901, 1 A LDO) from the 5 V rail through a ferrite bead
LDO_X, LDO_Y = FX - 8.0, 5.0
smd("U9", "TLV75901", ("Package_SON", "WSON-6-1EP_2x2mm_P0.65mm_EP1x1.6mm"), LDO_X, LDO_Y, 180, "C544759")
smd("R31", "75k", R0603, LDO_X + 2.6, 6.3, 90, "C23242")      # OUT -> FB: 0.55 V x (1 + 75/10) = 4.68 V
smd("R32", "10k", R0603, LDO_X + 4.2, 5.6, -90, "C25804")
smd("C20", "10uF", C0603, LDO_X - 2.4, 4.8, 90, "C19702")
smd("C21", "10uF", C0603, LDO_X + 0.2, 8.0, 0, "C19702")
smd("FB1", "BLM18PG221", ("Inductor_SMD", "L_0603_1608Metric"), LDO_X - 2.4, 7.9, 90, "C80165")
# plug-in filter socket: pin 2 = towards the front end, pin 4 = towards the radio module
J22_X, J22_Y = FX - 2.45 - 2.54, 25.0
place(lib_fp("J22", "868 filter", "Connector_PinSocket_2.54mm", "PinSocket_1x05_P2.54mm_Vertical"),
      J22_X, J22_Y, 90, "1x5 socket 2.54", "", assemble=False)
FE_REFS = ["U8", "U9", "L1", "L2", "L3", "L4", "L5", "L6", "L7", "L8", "L9", "FB1"] + \
          [r for r in ["C%d" % k for k in range(20, 36)] + ["R%d" % k for k in range(31, 38)] if r in parts]
# 868 MHz pi network: C9 is the fitted shunt of the antenna low-pass (C13 2.7 pF on the EK5), next to L6
_c9 = parts["C9"][0]
board.Remove(_c9)
del parts["C9"]
fe("C9", "2.7pF", C0402, 8.7, -1.6, 0, "C76904")

# ---- power input (top left): USB-C (power only) or JST-XH from the battery shield ----
j5 = place(lib_fp("J5", "USB-C power", "Connector_USB", "USB_C_Receptacle_GCT_USB4125-xx-x_6P_TopMnt_Horizontal"),
           3.2, 24.0, rot=-90, value="USB4125-GF-A", lcsc="C3151650")
j1 = place(lib_fp("J1", "5V IN", "Connector_JST", "JST_XH_B2B-XH-A_1x02_P2.50mm_Vertical"),
           5.0, 36.0, rot=0, value="JST-XH 2p", lcsc="C158012", assemble=False)
smd("R1", "5.1k", R0603, 9.5, 19.0, 90, "C23186")
smd("R2", "5.1k", R0603, 9.5, 29.0, 90, "C23186")
smd("Q1", "AO3401A", ("Package_TO_SOT_SMD", "SOT-23"), 15.0, 22.0, 0, "C15127")
smd("Q2", "AO3401A", ("Package_TO_SOT_SMD", "SOT-23"), 15.0, 30.0, 0, "C15127")
smd("R3", "10k", R0603, 19.5, 26.0, 90, "C25804")
smd("F1", "PTC 3A", ("Fuse", "Fuse_1812_4532Metric"), 23.0, 14.0, 0, "C21004")
smd("D1", "SMBJ5.0A", ("Diode_SMD", "D_SMB"), 29.0, 20.0, 90, "C83333")
smd("C1", "22uF", ("Capacitor_SMD", "C_1206_3216Metric"), 25.0, 26.0, 90, "C12891")
smd("C2", "22uF", ("Capacitor_SMD", "C_1206_3216Metric"), 29.0, 28.5, 90, "C12891")
smd("D4", "LED red", ("LED_SMD", "LED_0603_1608Metric"), 26.0, 34.0, 0, "C2286")
smd("R4", "1k", R0603, 22.5, 34.0, 0, "C21190")
# ESP 5 V feed (blocks back-feeding from a PC on the ESP32 USB port), between each ESP32 and the Pi
X_GAP_A = (X_DKA + 27.0 + PI_X) / 2          # centre of the gap between ESP32 A and the Pi
X_GAP_B = BOARD_W - X_GAP_A
# ESP32 A: diode and capacitor inside its socket next to its 5V pin (the 5 V rail passes there)
smd("D2", "SS34", ("Diode_SMD", "D_SMA"), X_DKA + 9.0, Y_DK + 50.8, 0, "C8678")
smd("C3", "10uF", C0603, X_DKA + 4.0, Y_DK + 47.5, 0, "C19702")
smd("D3", "SS34", ("Diode_SMD", "D_SMA"), X_GAP_B, 87.0, 90, "C8678")
smd("C4", "10uF", C0603, X_GAP_B + 3.0, 92.5, 90, "C19702")
# LR2021 decoupling next to the 3V3 pin, outside the module outline
#   HF: 3V3 pin top right (antenna end down) -> caps above the module
#   LF: 3V3 pin bottom left (antenna end up) -> caps under the module, next to that pin
smd("C5", "10uF", C0603, CX_HF + 6.0, CY_HF - 13.0, 0, "C19702")
smd("C6", "100nF", C0603, CX_HF + 2.0, CY_HF - 13.0, 0, "C14663")
smd("C8", "100nF", C0603, CX_LF - 4.0, CY_LF + 8.89, 0, "C14663")
smd("C7", "10uF", C0603, CX_LF - 4.0, CY_LF + 6.0, 0, "C19702")
# ESP reset / boot control from the Pi (Q3/Q4 = ESP32 A, Q5/Q6 = ESP32 B), next to the Pi
for (q, rg, rp, xx, yy) in (("Q3", "R11", "R15", X_GAP_A - 1.0, 64.0), ("Q4", "R12", "R16", X_GAP_A - 1.0, 71.5),
                            ("Q5", "R13", "R17", X_GAP_B + 1.0, 64.0), ("Q6", "R14", "R18", X_GAP_B + 1.0, 71.5)):
    s_ = 1 if xx < MID else -1          # gate resistor towards the Pi on both sides
    smd(q, "2N7002", ("Package_TO_SOT_SMD", "SOT-23"), xx, yy, 0, "C8545")
    smd(rg, "1k", R0603, xx + s_ * 3.6, yy, 90, "C21190")
    smd(rp, "10k", R0603, xx - 0.4, yy + 3.3, 0, "C25804")     # keeps the gate low while the Pi pin floats
# UART series resistors (protect both sides when only one of them has power)
smd("R5", "1k", R0603, X_GAP_A + 0.5, 56.0, 0, "C21190")
smd("R6", "1k", R0603, X_GAP_A + 0.5, 60.0, 0, "C21190")
smd("R7", "1k", R0603, X_GAP_B - 0.5, 56.0, 0, "C21190")
smd("R8", "1k", R0603, X_GAP_B - 0.5, 60.0, 0, "C21190")

# ---- connector panel in the middle, right above the Pi header pins it belongs to ----
#   left to right as on the header: I2C (pins 3/5), console / USB-UART (UART0, pins 8/10), GPS (UART5, 11/13/15)
PANEL_Y = 66.0
HDR3 = ("Connector_PinHeader_2.54mm", "PinHeader_1x03_P2.54mm_Vertical")
HDR4 = ("Connector_PinHeader_2.54mm", "PinHeader_1x04_P2.54mm_Vertical")
j12 = place(lib_fp("J12", "I2C", *HDR4), PI_X + 9.5, PANEL_Y - 8.0, rot=-90, value="1x4 2.54", assemble=False)
j4 = place(lib_fp("J4", "I2C", *HDR4), PI_X + 9.5, PANEL_Y, rot=-90, value="1x4 2.54", assemble=False)
j3 = place(lib_fp("J3", "CONSOLE", *HDR3), PI_X + 20.5, PANEL_Y, rot=-90, value="1x3 2.54", assemble=False)
j2 = place(lib_fp("J2", "GPS", "Connector_JST", "JST_XH_B5B-XH-A_1x05_P2.50mm_Vertical"),
           PI_X + 28.0, PANEL_Y, rot=0, value="JST-XH 5p", lcsc="C157991", assemble=False)
# console series resistors, I2C pull-ups to 3.3 V, 5 V buffer for the Pi
smd("R9", "1k", R0603, PI_X + 16.0, PANEL_Y + 5.5, 90, "C21190")
smd("R10", "1k", R0603, PI_X + 18.5, PANEL_Y + 5.5, 90, "C21190")
smd("R19", "4.7k", R0603, PI_X + 8.5, PANEL_Y + 5.5, 90, "C23162")
smd("R20", "4.7k", R0603, PI_X + 11.0, PANEL_Y + 5.5, 90, "C23162")
smd("C17", "22uF", ("Capacitor_SMD", "C_1206_3216Metric"), PI_X + 4.0, PANEL_Y + 6.0, 0, "C12891")


# ---- USB console (CH340C) between ESP32 A and the Pi: USB-C at the bottom edge ----
# The CH340C runs from the node's 3.3 V (same supply as the Pi, VBUS of the PC is not used), so no
# current can flow between the PC and the node through the data lines. TX/RX LEDs sit on the data
# lines and blink with the traffic (TX = PC to node, RX = node to PC).
G0 = X_GAP_A
CON_Y = BOARD_H - 3.4                         # USB-C front 0.25 mm over the board edge
U7_X, U7_Y = G0 - 2.0, 91.5                   # USBLC6-2SC6 ESD protection
U6_X, U6_Y = G0 + 4.65, U7_Y - 1.585          # CH340C (UD+ level with the ESD output)
place(lib_fp("J21", "USB-C console", "Connector_USB", "USB_C_Receptacle_HRO_TYPE-C-31-M-12"),
      G0, CON_Y, 0, "TYPE-C-31-M-12", "C165948")
smd("U7", "USBLC6-2SC6", ("Package_TO_SOT_SMD", "SOT-23-6"), U7_X, U7_Y, 0, "C7519")
smd("U6", "CH340C", ("Package_SO", "SOIC-16_3.9x9.9mm_P1.27mm"), U6_X, U6_Y, 0, "C84681")
smd("C18", "100nF", C0603, U6_X + 2.5, U6_Y - 7.2, 90, "C14663")
smd("C19", "4.7uF", C0603, U6_X, U6_Y - 7.2, 90, "C19666")
smd("R25", "5.1k", R0603, G0 - 6.45, CON_Y - 4.9, 90, "C23186")
smd("R26", "5.1k", R0603, G0 + 6.85, CON_Y - 4.9, 90, "C23186")
smd("D5", "LED red", ("LED_SMD", "LED_0603_1608Metric"), G0 - 5.75, 78.0, 0, "C2286")
smd("D6", "LED green", ("LED_SMD", "LED_0603_1608Metric"), G0 - 0.25, 78.0, 0, "C72043")
smd("R29", "1k", R0603, G0 - 5.75, 81.2, 0, "C21190")
smd("R30", "1k", R0603, G0 - 0.25, 81.2, 0, "C21190")
smd("R28", "4.7k", R0603, G0 - 3.25, 83.4, 0, "C23162")
smd("R27", "1k", R0603, G0 - 3.25, 85.6, 0, "C21190")

# ---- I2C expansion: Qwiic / STEMMA QT sockets (JST SH 4-pin: GND, 3V3, SDA, SCL), one shared bus ----
SH = ("Connector_JST", "JST_SH_SM04B-SRSS-TB_1x04-1MP_P1.00mm_Horizontal")
QWIIC = [("J6", MID - 5.5, 3.4, 180), ("J7", MID + 5.5, 3.4, 180),                          # top edge, centre
         ("J9", BOARD_W - 30.5, 3.4, 180), ("J10", BOARD_W - 21.5, 3.4, 180), ("J11", BOARD_W - 12.5, 3.4, 180),
         ("J8", MID - 18.0, 50.0, 180), ("J17", MID - 9.0, 50.0, 180), ("J18", MID, 50.0, 180),  # middle row
         ("J19", MID + 9.0, 50.0, 180), ("J20", MID + 18.0, 50.0, 180)]
for ref, x, y, r in QWIIC:
    place(lib_fp(ref, "Qwiic", *SH), x, y, r, "SM04B-SRSS-TB", "C160404")
QWIIC_REFS = [q[0] for q in QWIIC]

# references of the pi-network parts stay off the silkscreen (no room between the RF lines)
for _r in [x for t in PI_PARTS.values() for x in t] + FE_REFS:
    parts[_r][0].Reference().SetVisible(False)

# reference texts placed next to their parts where the default position collides
def ref_at(ref, x, y, angle=0):
    r = parts[ref][0].Reference()
    r.SetPosition(V(x, y))
    r.SetTextAngleDegrees(angle)


for _s, _x in ((1, X_GAP_A), (-1, X_GAP_B)):
    for _y, (rg, rp) in ((64.0, ("R11", "R15") if _s > 0 else ("R13", "R17")),
                         (71.5, ("R12", "R16") if _s > 0 else ("R14", "R18"))):
        ref_at(rg, _x + _s * 3.85, _y, 90)
        ref_at(rp, _x - _s * 1.0 - 0.4 + _s * 2.4, _y + 3.3)
for _r, _x in (("R19", PI_X + 8.5), ("R20", PI_X + 11.0), ("R9", PI_X + 16.0), ("R10", PI_X + 18.5)):
    ref_at(_r, _x, PANEL_Y + 8.0)
ref_at("C3", X_DKA + 4.0, Y_DK + 49.0)
ref_at("D2", X_DKA + 9.0, Y_DK + 53.2)
ref_at("R28", G0 - 6.1, 83.4)
ref_at("R27", G0 - 6.1, 85.6)
ref_at("R25", G0 - 6.45, CON_Y - 7.3)
ref_at("R26", G0 + 8.0, CON_Y - 4.9, 90)
ref_at("U6", U6_X, U6_Y)
for _g in list(parts["J21"][0].GraphicalItems()):      # no silkscreen at the board edge
    if _g.GetLayer() == pcbnew.F_SilkS and pcbnew.ToMM(_g.GetBoundingBox().GetBottom()) > BOARD_H - 1.6:
        parts["J21"][0].Remove(_g)
ref_at("C4", X_GAP_B + 3.0, 94.9)

mount_hole("H1", 3.5, 3.5)
mount_hole("H2", BOARD_W - 3.5, 3.5)
mount_hole("H3", X_DKA + 20.0, BOARD_H - 3.0)        # under the USB end of ESP32 A
mount_hole("H4", BOARD_W - X_DKA - 20.0, BOARD_H - 3.0)

# ----------------------------------------------------------------------------------------------
# Nets
# ----------------------------------------------------------------------------------------------
NETS = {
    "VIN": ["J1.1", "J5.A9", "J5.B9", "Q1.3", "Q2.3"],
    "VIN_P": ["Q1.2", "Q2.2", "F1.1"],
    "+5V": ["F1.2", "D1.1", "C1.1", "C2.1", "C17.1", "U5.2", "U5.4", "D2.2", "D3.2", "R4.1", "FB1.1"],
    "PFET_G": ["Q1.1", "Q2.1", "R3.1"],
    "CC1": ["J5.A5", "R1.1"],
    "CC2": ["J5.B5", "R2.1"],
    "LED_A": ["R4.2", "D4.2"],
    "+5V_ESPA": ["D2.1", "C3.1", "U1.21"],
    "+5V_ESPB": ["D3.1", "C4.1", "U2.21"],
    "+3V3_A": ["U1.1", "U1.2", "U3.8", "C5.1", "C6.1"],
    "+3V3_B": ["U2.1", "U2.2", "U4.8", "C7.1", "C8.1"],
    "+3V3_PI": ["U5.1", "U5.17", "J2.1", "J4.2", "J12.2", "R19.1", "R20.1", "U6.16", "U6.4", "C18.1", "C19.1",
                "D5.2", "D6.2"] + [r + ".2" for r in QWIIC_REFS],
    "EN_A": ["U1.3", "Q3.3"], "IO0_A": ["U1.36", "Q4.3"],
    "EN_B": ["U2.3", "Q5.3"], "IO0_B": ["U2.36", "Q6.3"],
    "PI_ENA": ["U5.29", "R11.1"], "G_ENA": ["R11.2", "Q3.1", "R15.1"],
    "PI_IO0A": ["U5.31", "R12.1"], "G_IO0A": ["R12.2", "Q4.1", "R16.1"],
    "PI_ENB": ["U5.32", "R13.1"], "G_ENB": ["R13.2", "Q5.1", "R17.1"],
    "PI_IO0B": ["U5.33", "R14.1"], "G_IO0B": ["R14.2", "Q6.1", "R18.1"],
    # ESP32 A (left) on UART4 (pins 7/16, left half of the header), ESP32 B (right) on UART3 (pins 27/28);
    # the node software finds the roles with GET_INFO, the port numbers do not matter
    "PI_TX4": ["U5.7", "R5.1"], "A_RXD": ["R5.2", "U1.26"],
    "A_TXD": ["U1.27", "R6.1"], "PI_RX4": ["R6.2", "U5.16"],
    "PI_TX3": ["U5.28", "R7.1"], "B_RXD": ["R7.2", "U2.26"],
    "B_TXD": ["U2.27", "R8.1"], "PI_RX3": ["R8.2", "U5.27"],
    "PI_TX0": ["U5.8", "R9.1", "R27.1", "R30.2"], "CON_TXD": ["R9.2", "J3.2"],
    "CON_RXD": ["J3.3", "R10.1"], "PI_RX0": ["R10.2", "U5.10", "R28.2"],
    # USB console (CH340C), powered from the node's 3.3 V
    "USB_DP": ["J21.A6", "J21.B6", "U7.1", "U7.6", "U6.5"],
    "USB_DM": ["J21.A7", "J21.B7", "U7.3", "U7.4", "U6.6"],
    "CC1_U": ["J21.A5", "R25.2"], "CC2_U": ["J21.B5", "R26.2"],
    "VBUS_U": ["J21.A4", "J21.B9", "J21.A9", "J21.B4", "U7.5"],
    "C_TXD": ["U6.2", "R28.1", "R29.2"], "LED_TX": ["R29.1", "D5.1"],
    "C_RXD": ["U6.3", "R27.2"], "LED_RX": ["R30.1", "D6.1"],
    "GPS_TX": ["J2.3", "U5.13"], "GPS_RX": ["J2.4", "U5.11"], "GPS_PPS": ["J2.5", "U5.15"],
    "I2C_SCL": ["J4.3", "U5.5", "J12.3", "R20.2"] + [r + ".4" for r in QWIIC_REFS],
    "I2C_SDA": ["J4.4", "U5.3", "J12.4", "R19.2"] + [r + ".3" for r in QWIIC_REFS],
    # ESP32 A <-> Core2021-HF   (U1 pad n = J1 pin n; GPIO: 4..7 -> pads 4..7, 15..18 -> 8..11, 8 -> 12, 9 -> 15)
    "CS_A": ["U1.10", "U3.11"], "SCK_A": ["U1.9", "U3.12"], "MOSI_A": ["U1.8", "U3.13"],
    "MISO_A": ["U1.7", "U3.14"], "NRST_A": ["U1.6", "U3.15"], "BUSY_A": ["U1.5", "U3.16"],
    "IRQ_A": ["U1.4", "U3.3"], "DIO7_A": ["U1.12", "U3.5"], "DIO8_A": ["U1.15", "U3.4"],
    # ESP32 B <-> Core2021-LF
    # 868 MHz front end (U8 SE2435L) and its supply (U9)
    "PA_VIN": ["FB1.2", "C20.1", "U9.6", "U9.4"],
    "PA_VCC": ["U9.1", "R31.1", "C21.2", "L5.2", "L3.2", "L4.2", "C22.1", "C23.1", "C24.1", "C25.1"],
    "PA_FB": ["U9.2", "R31.2", "R32.1"],
    "FE_VCC2": ["U8.21", "L5.1"], "FE_VCC0": ["U8.23", "L3.1", "C26.1"],
    "FE_VCC1": ["U8.24", "L4.1", "C27.1", "C28.1"],
    "FE_PAOUT": ["U8.20", "L2.1"], "FE_N1": ["L2.2", "L1.2", "C30.1", "C31.1"],
    "FE_TXIN": ["U8.16", "L1.1", "L7.1"], "FE_TRAP1": ["L7.2", "C32.1"],
    "FE_ANT1": ["U8.14", "L8.1"], "FE_N3": ["L8.2", "L9.2", "L6.1"], "FE_TRAP2": ["L9.1", "C33.2"],
    "FE_PAIN": ["U8.2", "C35.2"], "FE_TXFLT": ["U8.5", "C35.1"],
    "FE_LNAIN": ["U8.9", "R33.1"], "FE_RXFLT": ["U8.11", "R33.2"],
    "FE_CSD": ["U8.1", "R34.2"], "FE_CPS": ["U8.3", "R35.2"], "FE_CTX": ["U8.4", "R36.2"],
    "CSD_A": ["R34.1", "R37.1", "U1.28"], "CPS_A": ["R35.1", "U1.29"], "CTX_A": ["R36.1", "U1.30"],
    "CS_B": ["U2.11", "U4.11"], "SCK_B": ["U2.10", "U4.12"], "MOSI_B": ["U2.9", "U4.13"],
    "MISO_B": ["U2.6", "U4.14"], "NRST_B": ["U2.7", "U4.15"], "BUSY_B": ["U2.8", "U4.16"],
    "IRQ_B": ["U2.16", "U4.3"], "DIO7_B": ["U2.12", "U4.5"], "DIO8_B": ["U2.15", "U4.4"],
    "GND": ["J1.2", "J5.A12", "J5.B12", "J5.S1", "R1.2", "R2.2", "R3.2", "D1.2",
            "C1.2", "C2.2", "C17.2", "C3.2", "C4.2", "C5.2", "C6.2", "C7.2", "C8.2", "D4.1",
            "Q3.2", "Q4.2", "Q5.2", "Q6.2", "R15.2", "R16.2", "R17.2", "R18.2",
            "U5.9", "U5.14", "U5.20", "U5.25", "U5.30", "U5.34", "U5.39",
            "U1.22", "U1.23", "U1.43", "U1.44", "U2.22", "U2.23", "U2.43", "U2.44",
            "U3.2", "U3.7", "U3.10", "U4.2", "U4.7", "U4.10", "J2.2", "J3.1", "J4.1", "J12.1",
            "U6.1", "C18.2", "C19.2", "R25.1", "R26.1", "U7.2", "J21.A1", "J21.A12", "J21.B1", "J21.B12", "J21.S1",
            "U8.7", "U8.8", "U8.13", "U8.15", "U8.17", "U8.18", "U8.25", "U9.3", "U9.7", "R32.2", "R37.2",
            "C20.2", "C21.1", "C22.2", "C23.2", "C24.2", "C25.2", "C26.2", "C27.2", "C28.2", "C30.2", "C31.2",
            "C32.2", "C33.1", "J22.1", "J22.3", "J22.5"]
           + [r + ".1" for r in QWIIC_REFS] + [r + ".MP" for r in QWIIC_REFS]
           + [r + ".2" for r in ANT],
}
# RF nets: module pin -> shunt 1 -> series 0R -> shunt 2 -> SMA centre pin
RF_PIN = {"RF_HF_LORA": ("U3.9", "J13"), "RF_HF_24": ("U3.1", "J14"),
          "RF_LF_24": ("U4.1", "J15"), "RF_LF_LORA": ("U4.9", "J16")}
for name, (modpin, sma) in RF_PIN.items():
    rs, c1, c2 = PI_PARTS[name]
    NETS[name + "_M"] = [modpin, c1 + ".1", rs + ".1"]
    if name == "RF_HF_LORA":                 # 868 MHz: the pi network sits behind the front end
        NETS[name + "_M"] = ["L6.2", c1 + ".1", rs + ".1"]
        NETS[name + "_T"] = ["U8.6", "J22.2"]          # front end TR port <-> filter socket
        NETS[name + "_R"] = [modpin, "J22.4"]          # filter socket <-> radio module
    NETS[name + "_S"] = [rs + ".2", c2 + ".1", sma + ".1"]
    NETS["GND"] += [c1 + ".2", c2 + ".2"]
RF_NETS = [n for n in NETS if n.startswith("RF_")]

# Routing guides (areas a net must not use), so that the buses do not cross each other:
#  - ESP32 A has its LR2021 pins on the outer pin row. The SPI lines and 3V3 leave the socket to the
#    left, run up the left board edge and over the top end of the socket into the radio module; seen
#    from the module this keeps the pin order, so the bus needs no crossings.
#  - EN, IRQ, DIO7 and DIO8 of ESP32 A leave the socket to the right.
#  - The 5 V rail runs along the left board edge (outside the bus) and under the USB end of ESP32 A.
_A_IN = (X_DKA + 1.5, Y_DK - 1.5, X_DKA + 21.5, Y_DK + 45.0)          # inside the ESP32 A socket (above D2)
_A_WEST = [(X_DKA + 1.0, Y_DK - 0.3, CX_HF + 12.0, BOARD_H)]
_A_EAST = [(0.0, 38.0, X_DKA - 1.0, BOARD_H), (0.0, 38.0, CX_HF - 6.0, Y_DK - 0.9)]
KEEPOUT = {"+5V": [_A_IN, (2.1, 38.0, CX_HF + 13.0, 69.5), (X_DKA + 28.0, 79.0, PI_X + 1.0, 99.2),
                   (PI_X + 12.5, 60.0, PI_X + 62.0, PI_Y + 6.0)]}   # 5 V passes under the Pi, not over its header
# fixed lanes for the ESP32 A SPI bus: in the edge channel (x) and above the socket (y); lane 0 is next to
# the pins / lowest above the socket, the CS line is outermost and therefore the first one to turn
# into the radio module, which has CS as its lowest pin. 3V3 goes the other way (with EN/IRQ/DIO).
A_LANES = ["BUSY_A", "NRST_A", "MISO_A", "MOSI_A", "SCK_A", "CS_A"]
A_PIN = {"BUSY_A": 5, "NRST_A": 6, "MISO_A": 7, "MOSI_A": 8, "SCK_A": 9, "CS_A": 10}
LANE_PITCH = 0.65
for _k, _n in enumerate(A_LANES):
    xk = X_DKA - 1.45 - LANE_PITCH * _k
    yk = Y_DK - 1.35 - LANE_PITCH * _k
    pk = Y_DK + (A_PIN[_n] - 1) * 2.54
    KEEPOUT[_n] = _A_WEST + [
        (0.0, 30.0, xk - 0.1, 80.0),                   # left of its lane
        (0.0, 30.0, CX_HF - 6.7, yk - 0.1),            # above its lane
        (xk + 0.1, yk + 0.1, CX_HF - 6.0, pk - 0.9),   # right of / below its lane, above its pin
        (xk + 0.1, pk + 0.9, X_DKA + 1.0, 80.0),       # right of its lane, below its pin
    ]
for _n in ("CSD_A", "CPS_A", "CTX_A"):
    KEEPOUT[_n] = [(FX - 3.9, 0.0, BOARD_W, 38.6)]
for _n in ("EN_A", "IRQ_A", "DIO7_A", "DIO8_A", "+3V3_A"):
    KEEPOUT[_n] = _A_EAST
# ESP32 B: MISO/RST/BUSY reach the LoRa pin row from outside, MOSI/SCK/CS pass below it and reach it
# from inside the module, DIO7/DIO8/IRQ go around the module to the outside of the 2.4 GHz pin row
_LF_IN = (CX_LF - 6.4, CY_LF - 11.0, CX_LF + 6.4, CY_LF + 10.5)        # between the two pin rows
_LF_EAST = (CX_LF + 8.7, CY_LF - 11.0, X_DKB - 1.2, CY_LF + 9.8)      # outside the LoRa pin row
B_ORDER = ["MOSI_B", "SCK_B", "CS_B", "BUSY_B", "NRST_B", "MISO_B", "DIO7_B", "DIO8_B", "IRQ_B"]   # innermost first
_B_FRONT = (CX_LF + 10.0, Y_DK - 0.5, X_DKB - 1.2, Y_DK + 19.2)       # in front of ESP32 B pins 1-8
for _n in ("MISO_B", "NRST_B", "BUSY_B"):          # vertical next to ESP32 B, then straight into the pin
    KEEPOUT[_n] = [_LF_IN, (CX_LF + 5.0, CY_LF + 9.4, CX_LF + 11.0, Y_DK + 6.0)]
for _n in ("MOSI_B", "SCK_B", "CS_B"):
    KEEPOUT[_n] = [_LF_EAST, _B_FRONT]
for _n in ("DIO7_B", "DIO8_B", "IRQ_B"):
    KEEPOUT[_n] = [_LF_IN, _LF_EAST, _B_FRONT]
# the I2C bus and its 3.3 V stay out of the edge channel and away from the USB end of ESP32 A
_HF_IN = (CX_HF - 6.4, CY_HF - 10.5, CX_HF + 6.4, CY_HF + 11.0)
for _n in ("I2C_SDA", "I2C_SCL", "+3V3_PI"):
    KEEPOUT[_n] = [(0.0, 38.0, X_DKA - 1.0, BOARD_H), (0.0, Y_DK + 53.0, X_DKA + 27.0, BOARD_H), _LF_IN, _HF_IN]
WIDTH = {"VIN": 0.8, "VIN_P": 1.0, "+5V": 1.6, "+5V_ESPA": 0.6, "+5V_ESPB": 0.6,
         "+3V3_A": 0.25, "+3V3_B": 0.4, "+3V3_PI": 0.4}   # 3V3_A passes between header pins (module < 150 mA)
SIGNAL_W = 0.25
CLEAR = 0.15

fps = {fp.GetReference(): fp for fp in board.GetFootprints()}
for name, members in NETS.items():
    n = net(name)
    for m in members:
        ref, pad = m.split(".")
        found = [p for p in fps[ref].Pads() if p.GetNumber() == pad]
        assert found, m
        for p in found:
            p.SetNet(n)

# solid plane connection for the socket pins and all small SMD ground pads (thermal spokes would be
# starved between the neighbouring pins) and for the SMA connectors (solid RF ground at the launch)
for fp_ in board.GetFootprints():
    ref_ = fp_.GetReference()
    for p in fp_.Pads():
        if p.GetNetname() != "GND":
            continue
        if ref_ in ("U1", "U2", "U3", "U4", "U5", "J2", "J3", "J4", "J12") or ref_ in ANT or \
                p.GetAttribute() == pcbnew.PAD_ATTRIB_SMD:
            p.SetLocalZoneConnection(pcbnew.ZONE_CONNECTION_FULL)

# board outline
for a, b in (((0, 0), (BOARD_W, 0)), ((BOARD_W, 0), (BOARD_W, BOARD_H)),
             ((BOARD_W, BOARD_H), (0, BOARD_H)), ((0, BOARD_H), (0, 0))):
    s = pcbnew.PCB_SHAPE(board)
    s.SetShape(pcbnew.SHAPE_T_SEGMENT)
    s.SetStart(V(*a))
    s.SetEnd(V(*b))
    s.SetLayer(pcbnew.Edge_Cuts)
    s.SetWidth(MM(0.1))
    board.Add(s)

# ----------------------------------------------------------------------------------------------
# Router: A* on a 0.127 mm grid, two layers, clearance checked on the rasterised copper
# ----------------------------------------------------------------------------------------------
G = 0.127
NX, NY = int(round(BOARD_W / G)) + 1, int(round(BOARD_H / G)) + 1
F, B = 0, 1
occ = np.zeros((2, NY, NX), dtype=np.int32)       # 0 free, >0 net code, -1 obstacle
padmask = np.zeros((NY, NX), dtype=bool)          # no vias inside pads
net_ids = {name: i + 1 for i, name in enumerate(NETS)}
id_names = {v: k for k, v in net_ids.items()}

yy, xx = np.mgrid[0:NY, 0:NX]
XS, YS = xx * G, yy * G


def disk(r_mm):
    r = int(math.ceil(r_mm / G))
    y, x = np.mgrid[-r:r + 1, -r:r + 1]
    return (x * x + y * y) * G * G <= r_mm * r_mm


def pad_cells(p, grow):
    """Boolean mask of cells whose centre lies within the pad grown by `grow` mm."""
    bb = p.GetBoundingBox()
    x0, y0 = pcbnew.ToMM(bb.GetLeft()) - grow - G, pcbnew.ToMM(bb.GetTop()) - grow - G
    x1, y1 = pcbnew.ToMM(bb.GetRight()) + grow + G, pcbnew.ToMM(bb.GetBottom()) + grow + G
    i0, i1 = max(0, int(x0 / G)), min(NX - 1, int(x1 / G) + 1)
    j0, j1 = max(0, int(y0 / G)), min(NY - 1, int(y1 / G) + 1)
    m = np.zeros((NY, NX), dtype=bool)
    poly = p.GetEffectivePolygon(pcbnew.F_Cu if p.IsOnLayer(pcbnew.F_Cu) else pcbnew.B_Cu)
    for j in range(j0, j1 + 1):
        for i in range(i0, i1 + 1):
            pt = V(i * G, j * G)
            m[j, i] = poly.Collide(pt, MM(grow)) if grow > 0 else poly.Contains(pt)
    return m


pad_info = []      # (pad, net id, layers, inner-mask)
viamask = np.zeros((NY, NX), dtype=bool)   # no new via near existing vias / drilled holes
for fp in board.GetFootprints():
    for p in fp.Pads():
        if p.GetAttribute() == pcbnew.PAD_ATTRIB_NPTH:
            d = pcbnew.ToMM(p.GetDrillSize().x) / 2
            c = p.GetPosition()
            m = (XS - pcbnew.ToMM(c.x)) ** 2 + (YS - pcbnew.ToMM(c.y)) ** 2 <= (d + 0.3) ** 2
            occ[:, m] = -1
            padmask |= m
            continue
        if p.GetAttribute() == pcbnew.PAD_ATTRIB_PTH:
            c = p.GetPosition()
            rr = pcbnew.ToMM(p.GetDrillSize().x) / 2 + 0.15 + 0.55
            viamask |= (XS - pcbnew.ToMM(c.x)) ** 2 + (YS - pcbnew.ToMM(c.y)) ** 2 <= rr * rr
        nid = net_ids.get(p.GetNetname(), -1) if p.GetNetname() else -1
        layers = [L for L, cu in ((F, pcbnew.F_Cu), (B, pcbnew.B_Cu)) if p.IsOnLayer(cu)]
        outer = pad_cells(p, 0.09)
        for L in layers:
            cur = occ[L][outer]
            occ[L][outer] = np.where((cur == 0) | (cur == nid), nid, -1) if nid > 0 else -1
        padmask |= outer
        if nid > 0:
            inner = pad_cells(p, 0)
            pad_info.append((p, nid, layers, inner))

# mounting hole copper rings etc. are handled as pads above; board edge keep-out
edge = 0.45
emask = (XS < edge) | (YS < edge) | (XS > BOARD_W - edge) | (YS > BOARD_H - edge)
occ[:, emask] = -1


def blocked_for(nid, r_mm):
    out = np.zeros_like(occ, dtype=bool)
    for L in (F, B):
        foreign = (occ[L] != 0) & (occ[L] != nid)
        out[L] = ndimage.binary_dilation(foreign, structure=disk(r_mm))
    return out


# A* in C (astar.c, built on first use): 8 directions, costs for bends, vias and the bottom layer.
# The bottom layer is meant to stay a ground plane, signals use it only for short crossings.
import ctypes
_so = os.path.join(HERE, "astar.so")
if not os.path.exists(_so) or os.path.getmtime(_so) < os.path.getmtime(os.path.join(HERE, "astar.c")):
    os.system(f"gcc -O2 -shared -fPIC -o '{_so}' '{os.path.join(HERE, 'astar.c')}' -lm")
_lib = ctypes.CDLL(_so)
_u8 = np.ctypeslib.ndpointer(dtype=np.uint8, flags="C_CONTIGUOUS")
_f8 = np.ctypeslib.ndpointer(dtype=np.float64, flags="C_CONTIGUOUS")
_i4 = np.ctypeslib.ndpointer(dtype=np.int32, flags="C_CONTIGUOUS")
_lib.astar.argtypes = [ctypes.c_int, ctypes.c_int, _u8, _u8, _u8, _u8, _f8, _f8,
                       ctypes.c_double, ctypes.c_double, ctypes.c_long, _i4, ctypes.c_int]
_lib.astar.restype = ctypes.c_int
# per unit of length (one grid step): top orth, top diag, bottom orth, bottom diag; bend 45, bend 90; via; h weight
COSTS = np.array([1.0, 1.1, 4.0, 4.0, 2.0 / G, 6.0 / G, 6.0 / G, 1.0])
PREF = np.array([1.0, 1.0, 1.0, 1.0])
_out = np.zeros(3 * 400000, dtype=np.int32)


def astar(sources, targets, blk, via_ok, tcenter):
    """sources/targets: sets of (L, j, i). Returns the path source -> target as list of states, or None."""
    src = np.zeros((2, NY, NX), np.uint8)
    tgt = np.zeros((2, NY, NX), np.uint8)
    for (L, j, i) in sources:
        src[L, j, i] = 1
    for (L, j, i) in targets:
        tgt[L, j, i] = 1
    n = _lib.astar(NX, NY, np.ascontiguousarray(blk, dtype=np.uint8), np.ascontiguousarray(via_ok, dtype=np.uint8),
                   src, tgt, COSTS, PREF, float(tcenter[0]), float(tcenter[1]), 80000000, _out, 400000)
    if n <= 0:
        return None
    pts = _out[:3 * n].reshape(n, 3)
    return [(int(L), int(j), int(i)) for (L, j, i) in pts[::-1]]


tracks = []   # (net, width, layer, (x1,y1), (x2,y2))
vias = []     # (net, (x, y), size, drill)


def commit(nid, path, w):
    hw = w / 2
    pts_by_layer = {F: np.zeros((NY, NX), bool), B: np.zeros((NY, NX), bool)}
    for k, (L, j, i) in enumerate(path):
        pts_by_layer[L][j, i] = True
        if k and path[k - 1][0] != L:
            pts_by_layer[path[k - 1][0]][j, i] = True
            vias.append((nid, (i * G, j * G), 0.8 if w > 0.5 else 0.6, 0.4 if w > 0.5 else 0.3))
            viamask[(XS - i * G) ** 2 + (YS - j * G) ** 2 <= 1.0 ** 2] = True
    for L in (F, B):
        if pts_by_layer[L].any():
            grown = ndimage.binary_dilation(pts_by_layer[L], structure=disk(hw + 0.065))
            occ[L][grown & (occ[L] == 0)] = nid
    # via copper on both layers
    for k in range(1, len(path)):
        if path[k][0] != path[k - 1][0]:
            j, i = path[k][1], path[k][2]
            d = np.zeros((NY, NX), bool)
            d[j, i] = True
            d = ndimage.binary_dilation(d, structure=disk((0.4 if w > 0.5 else 0.3) + 0.065))
            for L in (F, B):
                occ[L][d & (occ[L] == 0)] = nid
    # segments: merge collinear steps per layer
    seg_start = path[0]
    prev = path[0]
    dirn = None
    for st in path[1:] + [None]:
        if st is not None and st[0] == prev[0]:
            d = (st[1] - prev[1], st[2] - prev[2])
            if dirn is None or d == dirn:
                dirn = d
                prev = st
                continue
        if prev != seg_start and seg_start[0] == prev[0]:
            tracks.append((nid, w, prev[0], (seg_start[2] * G, seg_start[1] * G), (prev[2] * G, prev[1] * G)))
        if st is None:
            break
        if st[0] != prev[0]:
            seg_start = st
            prev = st
            dirn = None
        else:
            seg_start = prev
            dirn = (st[1] - prev[1], st[2] - prev[2])
            prev = st


def route_net(name, tolerant=False):
    nid = net_ids[name]
    missed = 0
    w = WIDTH.get(name, SIGNAL_W)
    pins = [pi for pi in pad_info if pi[1] == nid]
    if len(pins) < 2:
        return True
    r = w / 2 + CLEAR + 0.05
    blk = blocked_for(nid, r)
    for (x0, y0, x1, y1) in KEEPOUT.get(name, []):
        blk[:, math.ceil(y0 / G):math.floor(y1 / G) + 1, math.ceil(x0 / G):math.floor(x1 / G) + 1] = True
    vblk = blocked_for(nid, (0.4 if w > 0.5 else 0.3) + CLEAR + 0.05)
    via_ok = ~vblk[F] & ~vblk[B] & ~padmask & ~viamask

    def cells(pi):
        p, _, layers, inner = pi
        js, is_ = np.nonzero(inner)
        out = set()
        for L in layers:
            for j, i in zip(js, is_):
                out.add((L, int(j), int(i)))
        return out

    # unblock own pad interiors
    for pi in pins:
        for L in pi[2]:
            blk[L][pi[3]] = False
    tree = cells(pins[0])
    todo = pins[1:]
    while todo:
        def dist(pi):
            c = pi[0].GetPosition()
            cx, cy = pcbnew.ToMM(c.x) / G, pcbnew.ToMM(c.y) / G
            return min(math.hypot(i - cx, j - cy) for (_, j, i) in list(tree)[::7] or tree)
        todo.sort(key=dist)
        nxt = todo.pop(0)
        c = nxt[0].GetPosition()
        tc = (pcbnew.ToMM(c.x) / G, pcbnew.ToMM(c.y) / G)
        path = astar(tree, cells(nxt), blk, via_ok, tc)
        if path is None:
            if not tolerant:
                return False
            missed += 1
            print("  GND pad not reached:", nxt[0].GetParentFootprint().GetReference(), nxt[0].GetNumber(), flush=True)
            continue
        commit(nid, path, w)
        # recompute blocking (own copper only grows, foreign unchanged) – reuse masks
        tree |= set(path) | cells(nxt)
    return True


def net_len(name):
    pins = [pi for pi in pad_info if pi[1] == net_ids[name]]
    xs = [pcbnew.ToMM(pi[0].GetPosition().x) for pi in pins]
    ys = [pcbnew.ToMM(pi[0].GetPosition().y) for pi in pins]
    return (max(xs) - min(xs)) + (max(ys) - min(ys)) if pins else 0


# ---- RF lines: drawn directly (not routed), 50 ohm grounded coplanar waveguide with via fence ----
def seg_mask(a, b, r):
    """Cells within r mm of segment a-b."""
    (x1, y1), (x2, y2) = a, b
    dx, dy = x2 - x1, y2 - y1
    L2 = dx * dx + dy * dy
    i0, i1 = max(0, int((min(x1, x2) - r) / G) - 1), min(NX - 1, int((max(x1, x2) + r) / G) + 2)
    j0, j1 = max(0, int((min(y1, y2) - r) / G) - 1), min(NY - 1, int((max(y1, y2) + r) / G) + 2)
    m = np.zeros((NY, NX), dtype=bool)
    px, py = XS[j0:j1, i0:i1], YS[j0:j1, i0:i1]
    t = np.clip(((px - x1) * dx + (py - y1) * dy) / L2, 0, 1) if L2 > 0 else 0
    d2 = (px - (x1 + t * dx)) ** 2 + (py - (y1 + t * dy)) ** 2
    m[j0:j1, i0:i1] = d2 <= r * r
    return m


def pt_seg(px, py, a, b):
    """Distance of point (px, py) from segment a-b."""
    dx, dy = b[0] - a[0], b[1] - a[1]
    L2 = dx * dx + dy * dy
    t = max(0.0, min(1.0, ((px - a[0]) * dx + (py - a[1]) * dy) / L2)) if L2 else 0.0
    return math.hypot(px - a[0] - t * dx, py - a[1] - t * dy)


rf_tracks, rf_vias = [], []
gid_rf = net_ids["GND"]
# 868 MHz: radio module -> filter socket pin 4, filter socket pin 2 -> front end (TR)
RF_EXTRA = {
    "RF_HF_LORA_R": [(CX_HF - 7.62, hf_bot), (J22_X + 7.62 + 3.0, hf_bot), (J22_X + 7.62, hf_bot - 3.0),
                     (J22_X + 7.62, J22_Y)],
    "RF_HF_LORA_T": [(J22_X + 2.54, J22_Y), (J22_X + 2.54, FY + 3.4)],
}
ALL_RF = [pp for (pp, _s) in RF_LINES.values()] + list(RF_EXTRA.values())
keep = RF_W / 2 + RF_GAP + 0.75          # nothing but ground within this distance of the line centre
fence_off = RF_W / 2 + RF_GAP + 0.45     # via fence: centre distance from the line centre
for name, (pts, side) in RF_LINES.items():
    rs = PI_PARTS[name][0]
    ser = fps[rs].GetPosition()
    sy = pcbnew.ToMM(ser.y)
    # split the polyline at the series resistor: module side net _M, SMA side net _S
    for (a, b) in zip(pts, pts[1:]):
        segs = [(a, b)]
        if abs(a[0] - b[0]) < 1e-6 and min(a[1], b[1]) < sy < max(a[1], b[1]):
            top, bot = (a, b) if a[1] < b[1] else (b, a)
            segs = [(bot, (bot[0], sy + 1.225)), ((top[0], sy - 1.225), top)]
        for (p, q) in segs:
            sma_side = max(p[1], q[1]) <= sy
            nid = net_ids[name + ("_S" if sma_side else "_M")]
            rf_tracks.append((nid, RF_W, F, p, q))
            band = seg_mask(p, q, keep)
            for L in (F, B):
                occ[L][band & (occ[L] == 0)] = -1
            core = seg_mask(p, q, RF_W / 2 + 0.065)
            occ[F][core & (occ[F] <= 0)] = nid
    # via fence on both sides of every segment
    for (a, b) in zip(pts, pts[1:]):
        dx, dy = b[0] - a[0], b[1] - a[1]
        ln = math.hypot(dx, dy)
        ux, uy = dx / ln, dy / ln
        nx_, ny_ = -uy, ux
        n_steps = int(ln / 1.8)
        for k in range(n_steps + 1):
            t = k / max(n_steps, 1)
            cx, cy = a[0] + dx * t, a[1] + dy * t
            for sgn in (-1, 1):
                vx, vy = cx + sgn * nx_ * fence_off, cy + sgn * ny_ * fence_off
                i, j = int(round(vx / G)), int(round(vy / G))
                if not (0 < i < NX - 1 and 0 < j < NY - 1):
                    continue
                near = (XS - vx) ** 2 + (YS - vy) ** 2 <= (0.3 + 0.2) ** 2
                if (padmask & near).any() or viamask[j, i] or emask[j, i]:
                    continue
                # keep away from every other RF line
                if any(pt_seg(vx, vy, p, q) < RF_W / 2 + RF_GAP + 0.3
                       for pp in ALL_RF for (p, q) in zip(pp, pp[1:])):
                    continue
                rf_vias.append((gid_rf, (vx, vy), 0.6, 0.3))
                viamask[(XS - vx) ** 2 + (YS - vy) ** 2 <= 1.0 ** 2] = True
                for L in (F, B):
                    occ[L][near & (occ[L] <= 0)] = gid_rf
for name, pts in RF_EXTRA.items():
    nid = net_ids[name]
    for (p, q) in zip(pts, pts[1:]):
        rf_tracks.append((nid, RF_W, F, p, q))
        band = seg_mask(p, q, keep)
        for L in (F, B):
            occ[L][band & (occ[L] == 0)] = -1
        core = seg_mask(p, q, RF_W / 2 + 0.065)
        occ[F][core & (occ[F] <= 0)] = nid
    for (a, b) in zip(pts, pts[1:]):
        dx, dy = b[0] - a[0], b[1] - a[1]
        ln = math.hypot(dx, dy)
        nx_, ny_ = -dy / ln, dx / ln
        n_steps = int(ln / 1.8)
        for k in range(n_steps + 1):
            t = k / max(n_steps, 1)
            cx, cy = a[0] + dx * t, a[1] + dy * t
            for sgn in (-1, 1):
                vx, vy = cx + sgn * nx_ * fence_off, cy + sgn * ny_ * fence_off
                i, j = int(round(vx / G)), int(round(vy / G))
                if not (0 < i < NX - 1 and 0 < j < NY - 1):
                    continue
                near = (XS - vx) ** 2 + (YS - vy) ** 2 <= (0.3 + 0.2) ** 2
                if (padmask & near).any() or viamask[j, i] or emask[j, i]:
                    continue
                if any(pt_seg(vx, vy, p, q) < RF_W / 2 + RF_GAP + 0.3
                       for pp in ALL_RF for (p, q) in zip(pp, pp[1:])):
                    continue
                rf_vias.append((gid_rf, (vx, vy), 0.6, 0.3))
                viamask[(XS - vx) ** 2 + (YS - vy) ** 2 <= 1.0 ** 2] = True
                for L in (F, B):
                    occ[L][near & (occ[L] <= 0)] = gid_rf
print(f"RF: {len(rf_tracks)} segments, {len(rf_vias)} fence vias", flush=True)
# ---- USB console: fixed fan-out of the USB-C receptacle (0.5 mm pitch) and the ESD chip ----
# Drawn directly like the RF lines; the router does not touch these nets.
def LC(x, y):                      # USB-C footprint coordinates -> board
    return (G0 + x, CON_Y + y)


_u7 = lambda x, y: (U7_X + x, U7_Y + y)
_p1, _p2, _p3 = _u7(-1.137, -0.95), _u7(-1.137, 0.0), _u7(-1.137, 0.95)      # D+ in, GND, D- in
_p6, _p5, _p4 = _u7(1.137, -0.95), _u7(1.137, 0.0), _u7(1.137, 0.95)         # D+ out, VBUS, D- out
_ud_p = (U6_X - 2.475, U6_Y + 0.635)                                          # CH340C UD+ (pin 5)
_ud_m = (U6_X - 2.475, U6_Y + 1.905)                                          # CH340C UD- (pin 6)
_r25 = (G0 - 6.45, CON_Y - 4.9 - 0.8)
_r26 = (G0 + 6.85, CON_Y - 4.9 - 0.8)
_x_dp, _x_dm = U7_X - 2.95, U7_X - 1.95                                       # vertical runs left of the ESD chip
FIXED = {   # net: [(layer, width, [points...]) ...], vias as ("via", (x, y))
    "USB_DP": [(F, 0.2, [LC(-0.25, -4.04), LC(-0.25, -5.15), LC(0.75, -5.15), LC(0.75, -4.04)]),
               (F, 0.2, [LC(-0.25, -5.15), LC(-0.25, -6.1), (G0 - 0.25, 95.0), (_x_dp, 95.0), (_x_dp, _p1[1]), _p1]),
               (F, 0.2, [_p6, _ud_p]),
               (F, 0.2, [_p1, (_p1[0], _p1[1] - 1.15), (_p6[0], _p6[1] - 1.15), _p6])],   # I/O1 in = out
    "USB_DM": [(F, 0.2, [LC(0.25, -4.04), LC(0.25, -2.6)]), (F, 0.2, [LC(-0.75, -4.04), LC(-0.75, -2.6)]),
               ("via", LC(0.25, -2.6)), ("via", LC(-0.75, -2.6)),
               (B, 0.2, [LC(0.25, -2.6), LC(-0.75, -2.6), (_x_dm, LC(-0.75, -2.6)[1] - (LC(-0.75, 0)[0] - _x_dm)),
                         (_x_dm, _p3[1] + 0.85)]),
               ("via", (_x_dm, _p3[1] + 0.85)),
               (F, 0.2, [(_x_dm, _p3[1] + 0.85), (_x_dm, _p3[1]), _p3]),
               (F, 0.2, [_p4, (_p4[0] + 1.0, _p4[1]), (_p4[0] + 1.0 + (_p4[1] - _ud_m[1]), _ud_m[1]), _ud_m]),
               (F, 0.2, [_p3, (_p3[0], _p3[1] + 1.25), (_p4[0], _p4[1] + 1.25), _p4])],   # I/O2 in = out
    "CC1_U": [(F, 0.2, [LC(-1.25, -4.04), LC(-1.25, -5.0), LC(-1.75, -5.5), LC(-1.75, -6.6),
                        (_r25[0], LC(0, -6.6)[1]), _r25])],
    "CC2_U": [(F, 0.2, [LC(1.75, -4.04), LC(1.75, -5.0), LC(2.45, -5.7), LC(2.45, -6.6),
                        (_r26[0], LC(0, -6.6)[1]), _r26])],
    "VBUS_U": [(F, 0.2, [LC(-2.45, -3.6), LC(-2.0, -3.0), LC(-2.0, -1.8)]),
               (F, 0.2, [LC(2.45, -3.6), LC(2.0, -3.0), LC(2.0, -1.8)]),
               ("via", LC(-2.0, -1.8)), ("via", LC(2.0, -1.8)),
               (B, 0.25, [LC(-2.0, -1.8), LC(2.0, -1.8), (U7_X, U7_Y)]),
               ("via", (U7_X, U7_Y)), (F, 0.2, [(U7_X, U7_Y), _p5])],
    "GND": [(F, 0.3, [_p2, (_p2[0] - 1.06, _p2[1])]), ("via", (_p2[0] - 1.06, _p2[1]))],
}

# ---- 868 MHz front end: all connections drawn (short, as on the evaluation board) ----
def PP(ref, num):
    """Board position of a pad."""
    for p in fps[ref].Pads():
        if p.GetNumber() == str(num):
            c = p.GetPosition()
            return (pcbnew.ToMM(c.x), pcbnew.ToMM(c.y))
    raise KeyError(ref + "." + str(num))


def U(u, v):
    return (FX + u, FY + v)


_bus_y = -6.0
FIXED.update({
    "FE_PAOUT": [(F, 0.3, [PP("U8", 20), U(0.75, -2.85), U(1.963, -2.85), PP("L2", 1)])],
    "FE_VCC2": [(F, 0.3, [PP("U8", 21), U(0.25, -3.6)])],
    "FE_N1": [(F, 0.3, [PP("L1", 2), U(3.6, -3.2)]), (F, 0.3, [PP("L2", 2), PP("C30", 1), PP("C31", 1)])],
    "FE_TXIN": [(F, 0.25, [PP("U8", 16), U(3.6, -0.25), PP("L1", 1)]), (F, 0.25, [U(3.6, -0.25), PP("L7", 1)])],
    "FE_TRAP1": [(F, 0.25, [PP("L7", 2), PP("C32", 1)])],
    "FE_ANT1": [(F, 0.25, [PP("U8", 14), U(2.7, 0.75), U(3.1, 1.15), PP("L8", 1)])],
    "FE_N3": [(F, 0.4, [PP("L8", 2), PP("L6", 1)]), (F, 0.3, [PP("L8", 2), PP("L9", 2)])],
    "FE_TRAP2": [(F, 0.3, [PP("L9", 1), PP("C33", 2)])],
    "FE_VCC0": [(F, 0.25, [PP("U8", 23), U(-0.75, -2.6), U(-0.9, -2.75), PP("L3", 1)]),
                (F, 0.25, [U(-0.9, -3.0), U(-2.1, -3.0), PP("C26", 1)])],
    "FE_VCC1": [(F, 0.2, [PP("U8", 24), U(-1.25, -2.5), U(-5.6, -2.5), PP("L4", 1)]),
                (F, 0.2, [U(-3.4, -2.5), PP("C27", 1)]), (F, 0.2, [U(-4.5, -2.5), PP("C28", 1)])],
    "PA_VCC": [(F, 0.5, [PP("L4", 2), U(-5.6, _bus_y)]), (F, 0.5, [U(-6.4, _bus_y), U(1.25, _bus_y)]),
               (F, 0.4, [PP("L3", 2), U(-0.9, _bus_y)]), (F, 0.4, [PP("L5", 2), U(0.4, _bus_y)]),
               (F, 0.3, [PP("C22", 1), U(-2.15, _bus_y)]), (F, 0.3, [PP("C23", 1), U(-0.85, _bus_y)]),
               (F, 0.3, [PP("C24", 1), U(1.25, _bus_y)]), (F, 0.3, [PP("C25", 1), U(0.2, _bus_y)]),
               (F, 0.4, [(LDO_X + 0.95, PP("U9", 1)[1]), (FX - 6.4, PP("U9", 1)[1]), U(-6.4, _bus_y)]),
               (F, 0.4, [PP("R31", 1), (FX - 6.4, PP("R31", 1)[1])]),
               (F, 0.4, [PP("C21", 2), (FX - 6.4, PP("C21", 2)[1])])],
    "PA_FB": [(F, 0.2, [PP("U9", 2), (PP("R31", 2)[0], PP("U9", 2)[1]), PP("R31", 2)]),
              (F, 0.2, [(PP("R31", 2)[0], PP("U9", 2)[1]), (PP("R32", 1)[0], PP("U9", 2)[1]), PP("R32", 1)])],
    "PA_VIN": [(F, 0.3, [PP("U9", 6), (LDO_X - 1.45, PP("U9", 6)[1]), (LDO_X - 1.45, PP("U9", 4)[1]), PP("U9", 4)]),
               (F, 0.4, [(LDO_X - 1.45, PP("U9", 6)[1]), PP("C20", 1), PP("FB1", 2)])],
    "FE_PAIN": [(F, 0.25, [PP("U8", 2), U(-3.2, -0.75)])],
    "FE_TXFLT": [(F, 0.25, [PP("U8", 5), U(-3.2, 0.75)])],
    "FE_CPS": [(F, 0.127, [PP("U8", 3), U(-2.45, -0.25), U(-2.5, -0.2), U(-4.95, -0.2), U(-5.5, -0.75),
                           PP("R35", 2)])],
    "FE_CTX": [(F, 0.127, [PP("U8", 4), U(-2.45, 0.25), U(-2.5, 0.2), U(-4.95, 0.2), U(-5.5, 0.75),
                           PP("R36", 2)])],
    "FE_CSD": [(F, 0.2, [PP("U8", 1), U(-2.45, -1.25), U(-2.45, -1.85), PP("R34", 2)])],
    "FE_LNAIN": [(F, 0.25, [PP("U8", 9), U(-0.25, 3.25)])],
    "FE_RXFLT": [(F, 0.25, [PP("U8", 11), U(0.75, 3.25)])],
    "RF_HF_LORA_T": [(F, 0.25, [PP("U8", 6), U(-2.45, 1.25), U(-2.45, 2.6)]),
                     (F, 0.6, [U(-2.45, 2.6), U(-2.45, 3.4)])],
    "RF_HF_LORA_M": [(F, 0.4, [U(6.6, -1.6), PP("C9", 1)])],
})
FIXED["GND"] += [(F, 0.25, [PP("U8", n), U(1.0, PP("U8", n)[1] - FY)]) for n in (13, 15, 17, 18)]
FIXED["GND"] += [(F, 0.25, [PP("U8", 8), U(-0.75, 1.0)]), (F, 0.2, [PP("U8", 7), U(-1.25, 2.25), U(-0.75, 2.25)]),
                 (F, 0.3, [PP("U9", 3), (LDO_X, PP("U9", 3)[1])])]
FIXED["GND"] += [("via", U(i * 0.85, j * 0.85)) for i in (-1, 0, 1) for j in (-1, 0, 1)]     # PA heat to the bottom
FIXED["GND"] += [("via", (LDO_X, LDO_Y - 0.4)), ("via", (LDO_X, LDO_Y + 0.4))]
# control lines ESP32 A -> front end: three parallel lanes left of the series resistors, down past the
# filter socket, then one via each and straight on the bottom layer to the ESP32 pins (the bus, 3V3 and
# UART lines of ESP32 A leave its socket to the right here, so the crossing is done once, underneath).
# CSD runs in the channel between the two J3 pin rows, CPS and CTX right of them.
_j3 = lambda gpio_pad: PP("U1", gpio_pad)            # pad on the 25.4 mm row (x = X_DKA + 25.4)
_xa = X_DKA + 25.4 - 1.27                           # channel between the J3 rows
_yv = 37.0                                          # via row, just above the ESP32 A bus lanes
_r34, _r35, _r36 = PP("R34", 1), PP("R35", 1), PP("R36", 1)
FIXED["CSD_A"] = [(F, 0.2, [_r34, PP("R37", 1)]),
                  (F, 0.2, [_r34, (32.0, _r34[1]), (32.0, 20.0), (_xa, 20.0 + _xa - 32.0), (_xa, _yv)]),
                  ("via", (_xa, _yv)),
                  (B, 0.2, [(_xa, _yv), (_xa, _j3(28)[1]), _j3(28)])]
FIXED["CPS_A"] = [(F, 0.2, [_r35, (32.6, _r35[1]), (32.6, 20.0), (33.6, 21.0), (33.6, 27.5), (36.6, 30.5), (36.6, _yv)]),
                  ("via", (36.6, _yv)),
                  (B, 0.2, [(36.6, _yv), (36.6, _j3(29)[1]), _j3(29)])]
FIXED["CTX_A"] = [(F, 0.2, [_r36, (_r36[0], 20.0), (_r36[0] + 0.9, 20.9), (_r36[0] + 0.9, 27.0),
                            (_r36[0] + 0.9 + 3.15, 30.15), (_r36[0] + 0.9 + 3.15, _yv + 0.8)]),
                  ("via", (_r36[0] + 0.9 + 3.15, _yv + 0.8)),
                  (B, 0.2, [(_r36[0] + 0.9 + 3.15, _yv + 0.8), (_r36[0] + 0.9 + 3.15, _j3(30)[1]), _j3(30)])]
# both alternative J3 rows (22.86 / 25.4 mm) of these three pins are tied together on the top layer
for _n, _pad in (("CSD_A", 28), ("CPS_A", 29), ("CTX_A", 30)):
    _y = PP("U1", _pad)[1]
    FIXED[_n].append((F, 0.25, [(X_DKA + 22.86, _y), (X_DKA + 25.4, _y)]))
FIXED["GND"] += [(F, 0.3, [PP("C9", 2), (PP("C9", 2)[0] + 0.9, PP("C9", 2)[1])]),
                 ("via", (PP("C9", 2)[0] + 0.9, PP("C9", 2)[1])),
                 (F, 0.3, [PP("C32", 2), U(5.45, -3.0)]), ("via", U(5.45, -3.0))]
FIXED_NETS = [n for n in FIXED if n != "GND"]
for name, items in FIXED.items():
    nid = net_ids[name]
    for it in items:
        if it[0] == "via":
            vx, vy = it[1]
            rf_vias.append((nid, (vx, vy), 0.6, 0.3))
            viamask[(XS - vx) ** 2 + (YS - vy) ** 2 <= 1.0 ** 2] = True
            vd = (XS - vx) ** 2 + (YS - vy) ** 2 <= (0.3 + 0.065) ** 2
            for L in (F, B):
                occ[L][vd & (occ[L] == 0)] = nid
            continue
        L, w, pts = it
        for p, q in zip(pts, pts[1:]):
            rf_tracks.append((nid, w, L, p, q))
            m = seg_mask(p, q, w / 2 + 0.065)
            occ[L][m & (occ[L] == 0)] = nid
print("console: fixed fan-out drawn", flush=True)

# ---- every SMD ground pad gets its own via to the bottom plane, placed before routing ----
pad_vias = 0
via_r = 0.3
for fp_ in board.GetFootprints():
    for p in fp_.Pads():
        if p.GetNetname() != "GND" or p.GetAttribute() != pcbnew.PAD_ATTRIB_SMD:
            continue
        if fp_.GetReference() in ("U7", "U8", "U9"):   # ground pins tied to the exposed pad (with vias)
            continue
        c = p.GetPosition()
        px, py = pcbnew.ToMM(c.x), pcbnew.ToMM(c.y)
        sx, sy = pcbnew.ToMM(p.GetSize().x), pcbnew.ToMM(p.GetSize().y)
        own = pad_cells(p, 0.09)
        best = None
        for d in np.arange(math.hypot(sx, sy) / 2 + 0.55, math.hypot(sx, sy) / 2 + 2.6, 0.2):
            for k in range(24):
                a = 2 * math.pi * k / 24
                vx, vy = float(px + d * math.cos(a)), float(py + d * math.sin(a))
                i, j = int(round(vx / G)), int(round(vy / G))
                if not (2 < i < NX - 3 and 2 < j < NY - 3) or viamask[j, i] or emask[j, i]:
                    continue
                vd = (XS - vx) ** 2 + (YS - vy) ** 2 <= (via_r + CLEAR + 0.05) ** 2
                if (padmask & vd & ~own).any():
                    continue
                if any(((occ[L][vd] != 0) & (occ[L][vd] != gid_rf)).any() for L in (F, B)):
                    continue
                tm = seg_mask((px, py), (vx, vy), 0.2 + CLEAR + 0.05)
                if ((occ[F][tm & ~own] != 0) & (occ[F][tm & ~own] != gid_rf)).any():
                    continue
                best = (vx, vy)
                break
            if best:
                break
        if not best:
            print("  no pad via for", fp_.GetReference(), p.GetNumber(), flush=True)
            continue
        vx, vy = best
        rf_vias.append((gid_rf, (vx, vy), 0.6, 0.3))
        rf_tracks.append((gid_rf, 0.4, F, (px, py), (vx, vy)))
        viamask[(XS - vx) ** 2 + (YS - vy) ** 2 <= 1.0 ** 2] = True
        vd = (XS - vx) ** 2 + (YS - vy) ** 2 <= (via_r + 0.065) ** 2
        for L in (F, B):
            occ[L][vd & (occ[L] == 0)] = gid_rf
        tm = seg_mask((px, py), (vx, vy), 0.2 + 0.065)
        occ[F][tm & (occ[F] == 0)] = gid_rf
        pad_vias += 1
print(f"ground: {pad_vias} pad vias", flush=True)

if os.environ.get("PLACE_ONLY"):
    # quick placement check: board with RF lines only
    for nid, w, L, a, b in rf_tracks:
        t = pcbnew.PCB_TRACK(board)
        t.SetStart(V(*a)); t.SetEnd(V(*b)); t.SetWidth(MM(w))
        t.SetLayer(pcbnew.F_Cu if L == F else pcbnew.B_Cu); t.SetNet(nets[id_names[nid]]); board.Add(t)
    for nid, (x, y), size, drill in rf_vias:
        v = pcbnew.PCB_VIA(board)
        v.SetPosition(V(x, y)); v.SetWidth(MM(size)); v.SetDrill(MM(drill))
        v.SetNet(nets[id_names[nid]]); board.Add(v)
    board.Save(OUT)
    sys.exit(0)

order = [n for n in NETS if n != "GND" and n not in RF_NETS and n not in FIXED_NETS]
BUS = ("CS_", "SCK_", "MOSI_", "MISO_", "NRST_", "BUSY_", "IRQ_", "DIO7_", "DIO8_")
# the module buses first (they need the straightest paths), then supplies, then the rest by length
def group(n):
    return (0 if n == "+5V" else 1 if n in A_LANES else 2 if n == "+3V3_A" else 3 if n in B_ORDER
            else 4 if n.startswith(BUS) else 5 if n in WIDTH else 6)


order.sort(key=lambda n: (group(n), -A_LANES.index(n) if n in A_LANES else B_ORDER.index(n) if n in B_ORDER
                          else net_len(n)))

occ_base = occ.copy()
viamask_base = viamask.copy()
failed = []
for attempt in range(3):
    occ[:] = occ_base
    viamask[:] = viamask_base
    tracks.clear()
    vias.clear()
    failed = []
    for name in order:
        if not route_net(name):
            failed.append(name)
    print(f"pass {attempt + 1}: {len(order) - len(failed)}/{len(order)} nets routed, failed: {failed}", flush=True)
    if not failed:
        break
    # nets that failed move to the front of their own group (the buses keep their planned order)
    order = sorted(order, key=lambda n: (group(n), 0 if n in failed else 1, order.index(n)))
tracks.extend(rf_tracks)
vias.extend(rf_vias)

# Ground comes from the two planes (pad vias + stitching). Pads that the planes did not reach in the
# previous build (listed by make_outputs.py from the DRC) get a short track to the nearest ground copper.
gnd_file = os.path.join(HERE, ".gnd_links.json")
gnd_pads = json.load(open(gnd_file)) if os.path.exists(gnd_file) else []
gid = net_ids["GND"]
for ref_pad in gnd_pads:
    ref_, pnum = ref_pad.split(".")
    pins = [pi for pi in pad_info if pi[1] == gid and pi[0].GetParentFootprint().GetReference() == ref_
            and pi[0].GetNumber() == pnum]
    for pi in pins:
        own = set()
        for L in pi[2]:
            js, is_ = np.nonzero(pi[3])
            own |= {(L, int(j), int(i)) for j, i in zip(js, is_)}
        r = 0.4 / 2 + CLEAR + 0.05
        blk = blocked_for(gid, r)
        vblk = blocked_for(gid, 0.3 + CLEAR + 0.05)
        via_ok = ~vblk[F] & ~vblk[B] & ~padmask & ~viamask
        grown = pad_cells(pi[0], 1.0)
        tgt = set()
        for L in (F, B):
            js, is_ = np.nonzero((occ[L] == gid) & ~grown)
            tgt |= {(L, int(j), int(i)) for j, i in zip(js, is_)}
        for L in pi[2]:
            blk[L][pi[3]] = False
        c = pi[0].GetPosition()
        path = astar(own, tgt, blk, via_ok, (pcbnew.ToMM(c.x) / G, pcbnew.ToMM(c.y) / G))
        if path:
            commit(gid, path, 0.4)
            print("  ground link for", ref_pad, flush=True)
        else:
            print("  no ground link for", ref_pad, flush=True)

print("stage: ground", flush=True)
# stitching vias between the two ground planes on a 6 mm grid
gid = net_ids["GND"]
vblk = blocked_for(gid, 0.3 + CLEAR + 0.05)
via_ok = ~vblk[F] & ~vblk[B] & ~padmask & ~viamask
step = int(5.0 / G)
grid_vias = 0
for j in range(step // 2, NY, step):
    for i in range(step // 2, NX, step):
        if via_ok[j, i]:
            vias.append((gid, (i * G, j * G), 0.6, 0.3))
            grid_vias += 1
print(f"ground: {grid_vias} stitching vias")
# check: drilled holes far enough apart
vx = [(x, y, d) for _, (x, y), _, d in vias]
close = [(a1, b1) for k, a1 in enumerate(vx) for b1 in vx[k + 1:]
         if math.hypot(a1[0] - b1[0], a1[1] - b1[1]) < a1[2] / 2 + b1[2] / 2 + 0.5]
print("vias too close:", len(close))

print("stage: write", flush=True)
# write tracks and vias
for nid, w, L, a, b in tracks:
    t = pcbnew.PCB_TRACK(board)
    t.SetStart(V(*a))
    t.SetEnd(V(*b))
    t.SetWidth(MM(w))
    t.SetLayer(pcbnew.F_Cu if L == F else pcbnew.B_Cu)
    t.SetNet(nets[id_names[nid]])
    board.Add(t)
for nid, (x, y), size, drill in vias:
    v = pcbnew.PCB_VIA(board)
    v.SetPosition(V(x, y))
    v.SetWidth(MM(size))
    v.SetDrill(MM(drill))
    v.SetNet(nets[id_names[nid]])
    board.Add(v)

print("stage: zones", flush=True)
# ground planes on both layers
for layer in (pcbnew.F_Cu, pcbnew.B_Cu):
    z = pcbnew.ZONE(board)
    z.SetLayer(layer)
    z.SetNet(nets["GND"])
    ol = z.Outline()
    ol.NewOutline()
    for x, y in ((0.3, 0.3), (BOARD_W - 0.3, 0.3), (BOARD_W - 0.3, BOARD_H - 0.3), (0.3, BOARD_H - 0.3)):
        ol.Append(MM(x), MM(y))
    z.SetLocalClearance(MM(0.3))
    z.SetMinThickness(MM(0.25))
    z.SetPadConnection(pcbnew.ZONE_CONNECTION_THERMAL)
    z.SetThermalReliefGap(MM(0.3))
    z.SetThermalReliefSpokeWidth(MM(0.4))
    z.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
    board.Add(z)
print("stage: labels", flush=True)

# board labels (only the name on the board, everything else labels a part or a connector pin)
board_text(f"LR2021 Node carrier v{VERSION}", MID, PI_Y + 17.0, 1.3)
board_text("by Raviolimeister (RAV1805)", MID, PI_Y + 19.2, 0.9)
board_text("5V IN: USB-C or J1 (+ left)", 22.0, 38.6, 0.8)
board_text("only ONE source at a time", 22.0, 40.1, 0.8)
# antenna connectors
for ref, (x, label) in ANT.items():
    pts, side = RF_LINES[{"J13": "RF_HF_LORA", "J14": "RF_HF_24", "J15": "RF_LF_24", "J16": "RF_LF_LORA"}[ref]]
    if ref == "J13":
        board_text("ANT " + label, x + 4.0, 12.8, 0.8, angle=90)
        continue
    board_text("ANT " + label, x + side * 4.2, 21.0, 0.8, angle=90)
board_text("868 PA/LNA", FX + 2.0, FY + 6.6, 0.8)
board_text("FILTER", J22_X + 4.4, J22_Y + 2.4, 0.8)
# connector pin labels (= pin names of the device that plugs in)
def pin_labels(names, x0, dx, y):
    for k, txt in enumerate(names):
        board_text(txt, x0 + k * dx, y, 0.8, thick=0.12)
pin_labels(("GND", "3V3", "SCL", "SDA"), PI_X + 9.5, -2.54, PANEL_Y - 2.6)
pin_labels(("GND", "3V3", "SCL", "SDA"), PI_X + 9.5, -2.54, PANEL_Y - 10.6)
board_text("I2C 3.3V", PI_X + 5.7, PANEL_Y - 12.0, 0.8)
pin_labels(("GND", "RXD", "TXD"), PI_X + 20.5, -2.54, PANEL_Y - 2.6)
board_text("CONSOLE", PI_X + 18.0, PANEL_Y - 5.6, 0.8)
board_text("(adapter)", PI_X + 18.0, PANEL_Y - 4.2, 0.8)
pin_labels(("3V3", "GND", "TX", "RX", "PPS"), PI_X + 28.0, 2.5, PANEL_Y - 3.8)
board_text("GPS", PI_X + 33.0, PANEL_Y - 5.4, 0.8)
board_text("USB CONSOLE", X_DKA + 27.6, 90.0, 0.8, angle=90)
board_text("TX", G0 - 3.35, 78.0, 0.8)
board_text("RX", G0 + 2.15, 78.0, 0.8)
board_text("I2C 3.3V", MID, 8.3, 0.8)
board_text("I2C 3.3V", BOARD_W - 21.5, 8.3, 0.8)
board_text("I2C 3.3V", MID, 54.6, 0.8)

print("stage: save", flush=True)
board.Save(OUT)
# fill the ground planes on a freshly loaded copy (filling the in-memory board crashes pcbnew)
print("stage: fill", flush=True)
filled = pcbnew.LoadBoard(OUT)
filled.BuildConnectivity()
filler = pcbnew.ZONE_FILLER(filled)
filler.Fill(filled.Zones())
# drop ground vias that ended up outside both planes (e.g. squeezed between two header rows)
dead = []
for t in filled.GetTracks():
    if t.GetClass() == "PCB_VIA" and t.GetNetname() == "GND":
        pos = t.GetPosition()
        if not any(z.GetFilledPolysList(L).Contains(pos) for z in filled.Zones()
                   for L in (pcbnew.F_Cu, pcbnew.B_Cu) if z.IsOnLayer(L)):
            if not any(tr.GetClass() != "PCB_VIA" and (tr.GetStart() == pos or tr.GetEnd() == pos)
                       for tr in filled.GetTracks()):
                dead.append(t)
for t in dead:
    filled.Remove(t)
if dead:
    print(f"removed {len(dead)} unconnected ground vias", flush=True)
    filled.BuildConnectivity()
    filler = pcbnew.ZONE_FILLER(filled)
    filler.Fill(filled.Zones())
filled.Save(OUT)

# netlist for documentation
with open(os.path.join(HERE, "netlist.json"), "w") as f:
    json.dump({k: v for k, v in NETS.items()}, f, indent=1)
with open(os.path.join(HERE, ".parts.json"), "w") as f:
    json.dump({ref: {"value": v, "lcsc": l, "assemble": a,
                     "footprint": fp.GetFPID().GetLibItemName().wx_str()}
               for ref, (fp, v, l, a) in parts.items()}, f, indent=1)

print("unrouted:", failed)
print("saved", OUT)
sys.exit(1 if failed else 0)
