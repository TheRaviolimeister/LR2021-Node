#!/usr/bin/env python3
"""LR2021 Node carrier board – generator.

Builds the KiCad PCB (placement, nets, routing, ground planes) from the definitions in this file and
writes lr2021-carrier.kicad_pcb. Run inside an environment with KiCad 9 (pcbnew Python module),
numpy and scipy:

    python3 generate_board.py

Afterwards `make_outputs.sh` runs the design rule check and writes Gerber, drill, BOM and placement
files for ordering.
"""
import heapq
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

VERSION = "1.1"
BOARD_W, BOARD_H = 156.0, 106.0

MM = pcbnew.FromMM


def V(x, y):
    return pcbnew.VECTOR2I(MM(x), MM(y))


board = pcbnew.BOARD()
board.SetCopperLayerCount(2)
ds = board.GetDesignSettings()
ds.m_TrackMinWidth = MM(0.2)
ds.m_ViasMinSize = MM(0.6)
ds.m_MinThroughDrill = MM(0.3)
ds.m_CopperEdgeClearance = MM(0.4)
ds.m_HoleToHoleMin = MM(0.5)
ds.m_HoleClearance = MM(0.25)
ds.m_MinClearance = MM(0.15)
ds.m_NetSettings.GetDefaultNetclass().SetClearance(MM(0.15))
ds.m_NetSettings.GetDefaultNetclass().SetTrackWidth(MM(0.25))
ds.SetAuxOrigin(V(0, BOARD_H))  # placement origin = lower left corner

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


# ---- placement / nets (carrier v1.1). Coordinates in mm, origin top left, y down. Antenna edge = top.
X_DKA, X_DKB = 4.0, 126.6        # J1 pin column of ESP32 A / B (both rotated 180 deg: USB at the bottom edge)
Y_DK = BOARD_H - 61.64           # y of J1 pin 1 (3V3) of both DevKits
u1 = place(devkit_socket("U1", "ESP32 A (868 MHz)"), X_DKA, Y_DK, rot=180, assemble=False)
u2 = place(devkit_socket("U2", "ESP32 B (433 MHz)"), X_DKB, Y_DK, rot=180, assemble=False)
# Core2021-HF: antenna end down, LoRa row left, 2.4 GHz row right
CX_HF, CY_HF = 51.0, 20.5
u3 = place(core_socket("U3", "Core2021-HF"), CX_HF, CY_HF, rot=-90, assemble=False)
# Core2021-LF: antenna end up, 2.4 GHz row left, LoRa row right
CX_LF, CY_LF = 105.0, 29.0
u4 = place(core_socket("U4", "Core2021-LF"), CX_LF, CY_LF, rot=90, assemble=False)
# Orange Pi Zero 2W centred at the bottom edge, ports to the edge
PI_X, PI_Y = BOARD_W / 2 - 32.5, BOARD_H - 30.3
u5 = place(pi_socket("U5"), PI_X, PI_Y, assemble=False)

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
    "J15": (BOARD_W - (CX_HF + 11.62), "2.4G LF"),
    "J16": (BOARD_W - (CX_HF - 11.62), "433 LoRa"),
}
for ref, (x, label) in ANT.items():
    place(lib_fp(ref, "SMA " + label, *SMA), x, SMA_Y, 0, "BWSMA-KWE-Z001", "C496551")

# RF lines (50 ohm grounded coplanar waveguide) as point lists from the module pin to the SMA pin.
# Each line has a pi network near the SMA: shunt (not fitted) - series 0 ohm - shunt (not fitted).
RF_W, RF_GAP = 1.55, 0.30
PI_SH_SMA, PI_SER, PI_SH_MOD = 12.5, 15.1, 17.7      # y of the pi-network parts
hf_bot = CY_HF + 8.89
lf_top = CY_LF - 8.89
RF_LINES = {
    # name: (points, side of the shunt parts)
    "RF_HF_LORA": ([(CX_HF - 7.62, hf_bot), (CX_HF - 10.12, hf_bot), (CX_HF - 11.62, hf_bot - 1.5),
                    (CX_HF - 11.62, SMA_Y)], -1),
    "RF_HF_24": ([(CX_HF + 7.62, hf_bot), (CX_HF + 10.12, hf_bot), (CX_HF + 11.62, hf_bot - 1.5),
                  (CX_HF + 11.62, SMA_Y)], +1),
    "RF_LF_24": ([(CX_LF - 7.62, lf_top), (CX_LF - 7.62, 11.61), (ANT["J15"][0], 7.61),
                  (ANT["J15"][0], SMA_Y)], -1),
    "RF_LF_LORA": ([(CX_LF + 7.62, lf_top), (CX_LF + 7.62, 11.61), (ANT["J16"][0], 7.61),
                    (ANT["J16"][0], SMA_Y)], +1),
}
PI_PARTS = {}   # line name -> (series ref, shunt module side ref, shunt sma side ref)
rser, csh = 21, 9
for name, (pts, side) in RF_LINES.items():
    xs = [a[0] for a, b in zip(pts, pts[1:]) if abs(a[0] - b[0]) < 1e-6 and min(a[1], b[1]) <= PI_SH_SMA - 0.6
          and max(a[1], b[1]) >= PI_SH_MOD + 0.6]
    assert xs, name
    x = xs[0]
    rs, c1, c2 = f"R{rser}", f"C{csh}", f"C{csh + 1}"
    smd(rs, "0R", R0603, x, PI_SER, 90, "C21189")
    smd(c1, "DNP", C0603, x + side * 0.8, PI_SH_MOD, 0 if side > 0 else 180, assemble=False)
    smd(c2, "DNP", C0603, x + side * 0.8, PI_SH_SMA, 0 if side > 0 else 180, assemble=False)
    PI_PARTS[name] = (rs, c1, c2)
    rser += 1
    csh += 2

# ---- power input (top left): USB-C (power only) or JST-XH from the battery shield ----
j5 = place(lib_fp("J5", "USB-C power", "Connector_USB", "USB_C_Receptacle_GCT_USB4125-xx-x_6P_TopMnt_Horizontal"),
           3.2, 24.0, rot=-90, value="USB4125-GF-A", lcsc="C3151650")
j1 = place(lib_fp("J1", "5V IN", "Connector_JST", "JST_XH_B2B-XH-A_1x02_P2.50mm_Vertical"),
           5.0, 37.0, rot=0, value="JST-XH 2p", lcsc="C158012", assemble=False)
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
# ESP 5 V feed (blocks back-feeding from a PC on the ESP32 USB port)
smd("D2", "SS34", ("Diode_SMD", "D_SMA"), 36.5, 84.0, 90, "C8678")
smd("C3", "10uF", C0603, 40.5, 84.0, 90, "C19702")
smd("D3", "SS34", ("Diode_SMD", "D_SMA"), BOARD_W - 36.5, 84.0, 90, "C8678")
smd("C4", "10uF", C0603, BOARD_W - 40.5, 84.0, 90, "C19702")
# LR2021 decoupling (between the socket rows, close to the 3V3 pin)
smd("C5", "10uF", C0603, CX_HF + 4.5, CY_HF - 7.5, 90, "C19702")
smd("C6", "100nF", C0603, CX_HF + 2.0, CY_HF - 7.5, 90, "C14663")
smd("C7", "10uF", C0603, CX_LF - 4.5, CY_LF + 7.5, 90, "C19702")
smd("C8", "100nF", C0603, CX_LF - 2.0, CY_LF + 7.5, 90, "C14663")
# ESP reset / boot control from the Pi (Q3/Q4 = ESP32 A, Q5/Q6 = ESP32 B)
smd("Q3", "2N7002", ("Package_TO_SOT_SMD", "SOT-23"), 37.0, 50.0, 0, "C8545")
smd("R11", "1k", R0603, 41.0, 50.0, 90, "C21190")
smd("R15", "100k", R0603, 37.0, 54.0, 0, "C25803")
smd("Q4", "2N7002", ("Package_TO_SOT_SMD", "SOT-23"), 37.0, 62.0, 0, "C8545")
smd("R12", "1k", R0603, 41.0, 62.0, 90, "C21190")
smd("R16", "100k", R0603, 37.0, 66.0, 0, "C25803")
smd("Q5", "2N7002", ("Package_TO_SOT_SMD", "SOT-23"), BOARD_W - 37.0, 50.0, 0, "C8545")
smd("R13", "1k", R0603, BOARD_W - 41.0, 50.0, 90, "C21190")
smd("R17", "100k", R0603, BOARD_W - 37.0, 54.0, 0, "C25803")
smd("Q6", "2N7002", ("Package_TO_SOT_SMD", "SOT-23"), BOARD_W - 37.0, 62.0, 0, "C8545")
smd("R14", "1k", R0603, BOARD_W - 41.0, 62.0, 90, "C21190")
smd("R18", "100k", R0603, BOARD_W - 37.0, 66.0, 0, "C25803")
# UART series resistors (protect both sides when only one of them has power)
smd("R5", "1k", R0603, 36.0, 72.0, 0, "C21190")
smd("R6", "1k", R0603, 40.0, 72.0, 0, "C21190")
smd("R7", "1k", R0603, BOARD_W - 40.0, 72.0, 0, "C21190")
smd("R8", "1k", R0603, BOARD_W - 36.0, 72.0, 0, "C21190")
smd("R9", "1k", R0603, 130.0, 38.0, 0, "C21190")
smd("R10", "1k", R0603, 134.0, 38.0, 0, "C21190")
# I2C pull-ups to 3.3 V
smd("R19", "4.7k", R0603, BOARD_W / 2 - 18.0, PI_Y - 4.0, 0, "C23162")
smd("R20", "4.7k", R0603, BOARD_W / 2 - 14.0, PI_Y - 4.0, 0, "C23162")

# ---- connectors (top right): GPS, console, I2C pin headers ----
j2 = place(lib_fp("J2", "GPS", "Connector_JST", "JST_XH_B5B-XH-A_1x05_P2.50mm_Vertical"),
           BOARD_W - 4.0, 26.0, rot=90, value="JST-XH 5p", lcsc="C157991", assemble=False)
j3 = place(lib_fp("J3", "CONSOLE", "Connector_PinHeader_2.54mm", "PinHeader_1x03_P2.54mm_Vertical"),
           BOARD_W - 3.5, 31.0, rot=0, value="1x3 2.54", assemble=False)
HDR4 = ("Connector_PinHeader_2.54mm", "PinHeader_1x04_P2.54mm_Vertical")
j4 = place(lib_fp("J4", "I2C", *HDR4), 132.0, 15.0, rot=0, value="1x4 2.54", assemble=False)
j12 = place(lib_fp("J12", "I2C", *HDR4), 139.0, 15.0, rot=0, value="1x4 2.54", assemble=False)

# ---- I2C expansion: Qwiic / STEMMA QT sockets (JST SH 4-pin: GND, 3V3, SDA, SCL), one shared bus ----
SH = ("Connector_JST", "JST_SH_SM04B-SRSS-TB_1x04-1MP_P1.00mm_Horizontal")
QWIIC = [("J6", 12.5, 3.4, 180), ("J7", 21.5, 3.4, 180), ("J8", 30.5, 3.4, 180),        # top edge, left
         ("J9", 125.5, 3.4, 180), ("J10", 134.5, 3.4, 180), ("J11", 143.5, 3.4, 180),  # top edge, right
         ("J17", 38.25, BOARD_H - 3.4, 0), ("J18", BOARD_W - 38.25, BOARD_H - 3.4, 0),  # bottom edge
         ("J19", 70.0, 44.0, 0), ("J20", 86.0, 44.0, 0)]                                 # centre
for ref, x, y, r in QWIIC:
    place(lib_fp(ref, "Qwiic", *SH), x, y, r, "SM04B-SRSS-TB", "C160404")
QWIIC_REFS = [q[0] for q in QWIIC]

# references of the pi-network parts and the parts under the radio modules stay off the silkscreen
for _r in [x for t in PI_PARTS.values() for x in t] + ["C5", "C6", "C7", "C8"]:
    parts[_r][0].Reference().SetVisible(False)

mount_hole("H1", 3.5, 3.5)
mount_hole("H2", BOARD_W - 3.5, 3.5)
mount_hole("H3", 38.25, BOARD_H - 12.0)
mount_hole("H4", BOARD_W - 38.25, BOARD_H - 12.0)

# ----------------------------------------------------------------------------------------------
# Nets
# ----------------------------------------------------------------------------------------------
NETS = {
    "VIN": ["J1.1", "J5.A9", "J5.B9", "Q1.3", "Q2.3"],
    "VIN_P": ["Q1.2", "Q2.2", "F1.1"],
    "+5V": ["F1.2", "D1.1", "C1.1", "C2.1", "U5.2", "U5.4", "D2.2", "D3.2", "R4.1"],
    "PFET_G": ["Q1.1", "Q2.1", "R3.1"],
    "CC1": ["J5.A5", "R1.1"],
    "CC2": ["J5.B5", "R2.1"],
    "LED_A": ["R4.2", "D4.2"],
    "+5V_ESPA": ["D2.1", "C3.1", "U1.21"],
    "+5V_ESPB": ["D3.1", "C4.1", "U2.21"],
    "+3V3_A": ["U1.1", "U1.2", "U3.8", "C5.1", "C6.1"],
    "+3V3_B": ["U2.1", "U2.2", "U4.8", "C7.1", "C8.1"],
    "+3V3_PI": ["U5.1", "U5.17", "J2.1", "J4.2", "J12.2", "R19.1", "R20.1"] + [r + ".2" for r in QWIIC_REFS],
    "EN_A": ["U1.3", "Q3.3"], "IO0_A": ["U1.36", "Q4.3"],
    "EN_B": ["U2.3", "Q5.3"], "IO0_B": ["U2.36", "Q6.3"],
    "PI_ENA": ["U5.29", "R11.1"], "G_ENA": ["R11.2", "Q3.1", "R15.1"],
    "PI_IO0A": ["U5.31", "R12.1"], "G_IO0A": ["R12.2", "Q4.1", "R16.1"],
    "PI_ENB": ["U5.32", "R13.1"], "G_ENB": ["R13.2", "Q5.1", "R17.1"],
    "PI_IO0B": ["U5.33", "R14.1"], "G_IO0B": ["R14.2", "Q6.1", "R18.1"],
    "PI_TX3": ["U5.28", "R5.1"], "A_RXD": ["R5.2", "U1.26"],
    "A_TXD": ["U1.27", "R6.1"], "PI_RX3": ["R6.2", "U5.27"],
    "PI_TX4": ["U5.7", "R7.1"], "B_RXD": ["R7.2", "U2.26"],
    "B_TXD": ["U2.27", "R8.1"], "PI_RX4": ["R8.2", "U5.16"],
    "PI_TX0": ["U5.8", "R9.1"], "CON_TXD": ["R9.2", "J3.2"],
    "CON_RXD": ["J3.3", "R10.1"], "PI_RX0": ["R10.2", "U5.10"],
    "GPS_TX": ["J2.3", "U5.13"], "GPS_RX": ["J2.4", "U5.11"], "GPS_PPS": ["J2.5", "U5.15"],
    "I2C_SCL": ["J4.3", "U5.5", "J12.3", "R20.2"] + [r + ".4" for r in QWIIC_REFS],
    "I2C_SDA": ["J4.4", "U5.3", "J12.4", "R19.2"] + [r + ".3" for r in QWIIC_REFS],
    # ESP32 A <-> Core2021-HF   (U1 pad n = J1 pin n; GPIO: 4..7 -> pads 4..7, 15..18 -> 8..11, 8 -> 12, 9 -> 15)
    "CS_A": ["U1.10", "U3.11"], "SCK_A": ["U1.9", "U3.12"], "MOSI_A": ["U1.8", "U3.13"],
    "MISO_A": ["U1.7", "U3.14"], "NRST_A": ["U1.6", "U3.15"], "BUSY_A": ["U1.5", "U3.16"],
    "IRQ_A": ["U1.4", "U3.3"], "DIO7_A": ["U1.12", "U3.5"], "DIO8_A": ["U1.15", "U3.4"],
    # ESP32 B <-> Core2021-LF
    "CS_B": ["U2.11", "U4.11"], "SCK_B": ["U2.10", "U4.12"], "MOSI_B": ["U2.9", "U4.13"],
    "MISO_B": ["U2.6", "U4.14"], "NRST_B": ["U2.7", "U4.15"], "BUSY_B": ["U2.8", "U4.16"],
    "IRQ_B": ["U2.16", "U4.3"], "DIO7_B": ["U2.12", "U4.5"], "DIO8_B": ["U2.15", "U4.4"],
    "GND": ["J1.2", "J5.A12", "J5.B12", "J5.S1", "R1.2", "R2.2", "R3.2", "D1.2",
            "C1.2", "C2.2", "C3.2", "C4.2", "C5.2", "C6.2", "C7.2", "C8.2", "D4.1",
            "Q3.2", "Q4.2", "Q5.2", "Q6.2", "R15.2", "R16.2", "R17.2", "R18.2",
            "U5.6", "U5.9", "U5.14", "U5.20", "U5.25", "U5.30", "U5.34", "U5.39",
            "U1.22", "U1.23", "U1.43", "U1.44", "U2.22", "U2.23", "U2.43", "U2.44",
            "U3.2", "U3.7", "U3.10", "U4.2", "U4.7", "U4.10", "J2.2", "J3.1", "J4.1", "J12.1"]
           + [r + ".1" for r in QWIIC_REFS] + [r + ".MP" for r in QWIIC_REFS]
           + [r + ".2" for r in ANT],
}
# RF nets: module pin -> shunt 1 -> series 0R -> shunt 2 -> SMA centre pin
RF_PIN = {"RF_HF_LORA": ("U3.9", "J13"), "RF_HF_24": ("U3.1", "J14"),
          "RF_LF_24": ("U4.1", "J15"), "RF_LF_LORA": ("U4.9", "J16")}
for name, (modpin, sma) in RF_PIN.items():
    rs, c1, c2 = PI_PARTS[name]
    NETS[name + "_M"] = [modpin, c1 + ".1", rs + ".1"]
    NETS[name + "_S"] = [rs + ".2", c2 + ".1", sma + ".1"]
    NETS["GND"] += [c1 + ".2", c2 + ".2"]
RF_NETS = [n for n in NETS if n.startswith("RF_")]

WIDTH = {"VIN": 0.8, "VIN_P": 1.0, "+5V": 1.0, "+5V_ESPA": 0.6, "+5V_ESPB": 0.6,
         "+3V3_A": 0.5, "+3V3_B": 0.5, "+3V3_PI": 0.4}
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
# starved between the neighbouring pins); the SMA connectors and the power jacks keep thermals
for fp_ in board.GetFootprints():
    ref_ = fp_.GetReference()
    for p in fp_.Pads():
        if p.GetNetname() != "GND":
            continue
        if ref_ in ("U1", "U2", "U3", "U4", "U5", "J2", "J3", "J4", "J12") or \
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


SQ2 = math.sqrt(2)
MOVES = [(1, 0, 1.0), (-1, 0, 1.0), (0, 1, 1.0), (0, -1, 1.0),
         (1, 1, SQ2), (1, -1, SQ2), (-1, 1, SQ2), (-1, -1, SQ2)]
VIA_COST = 30.0


def astar(sources, targets, blk, via_ok, tcenter):
    """sources/targets: sets of (L, j, i). Returns list of states or None."""
    tx, ty = tcenter
    best = {}
    heap = []
    for s in sources:
        best[s] = 0.0
        L, j, i = s
        h = math.hypot(i - tx, j - ty)
        heapq.heappush(heap, (h, 0.0, s, None))
    came = {}
    n = 0
    while heap:
        f, g, s, prev = heapq.heappop(heap)
        if s in came:
            continue
        came[s] = prev
        if s in targets:
            path = []
            while s is not None:
                path.append(s)
                s = came[s]
            return path[::-1]
        n += 1
        if n > 2500000:
            return None
        L, j, i = s
        for di, dj, c in MOVES:
            ni, nj = i + di, j + dj
            if ni < 0 or nj < 0 or ni >= NX or nj >= NY:
                continue
            if blk[L, nj, ni]:
                continue
            if di and dj and (blk[L, j, ni] or blk[L, nj, i]):
                continue
            # layer preference: top horizontal, bottom vertical
            pen = 1.0
            if L == F and dj and not di:
                pen = 1.6
            if L == B and di and not dj:
                pen = 1.6
            ng = g + c * pen
            st = (L, nj, ni)
            if ng < best.get(st, 1e18):
                best[st] = ng
                heapq.heappush(heap, (ng + math.hypot(ni - tx, nj - ty), ng, st, s))
        if via_ok[j, i]:
            st = (1 - L, j, i)
            ng = g + VIA_COST
            if ng < best.get(st, 1e18):
                best[st] = ng
                heapq.heappush(heap, (ng + math.hypot(i - tx, j - ty), ng, st, s))
    return None


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
                       for (pp, _s) in RF_LINES.values() for (p, q) in zip(pp, pp[1:])):
                    continue
                rf_vias.append((gid_rf, (vx, vy), 0.6, 0.3))
                viamask[(XS - vx) ** 2 + (YS - vy) ** 2 <= 1.0 ** 2] = True
                for L in (F, B):
                    occ[L][near & (occ[L] <= 0)] = gid_rf
print(f"RF: {len(rf_tracks)} segments, {len(rf_vias)} fence vias", flush=True)
# ---- every SMD ground pad gets its own via to the bottom plane, placed before routing ----
pad_vias = 0
via_r = 0.3
for fp_ in board.GetFootprints():
    for p in fp_.Pads():
        if p.GetNetname() != "GND" or p.GetAttribute() != pcbnew.PAD_ATTRIB_SMD:
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
        t.SetLayer(pcbnew.F_Cu); t.SetNet(nets[id_names[nid]]); board.Add(t)
    board.Save(OUT)
    sys.exit(0)

order_file = os.path.join(HERE, ".route_order.json")
order = [n for n in NETS if n != "GND" and n not in RF_NETS]
order.sort(key=lambda n: (0 if n in WIDTH else 1, net_len(n)))
if os.path.exists(order_file):
    saved = json.load(open(order_file))
    order = [n for n in saved if n in order] + [n for n in order if n not in saved]

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
    order = failed + [n for n in order if n not in failed]
json.dump(order, open(order_file, "w"))
tracks.extend(rf_tracks)
vias.extend(rf_vias)

# ground as a routed tree as well (the planes alone cannot reach every pad between the tracks)
WIDTH["GND"] = 0.4
route_net("GND", tolerant=True)

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

# board labels
board_text(f"LR2021 Node carrier v{VERSION}", BOARD_W / 2, PI_Y + 17.0, 1.3)
board_text("by Raviolimeister (RAV1805)", BOARD_W / 2, PI_Y + 19.2, 0.9)
board_text("GPL-3.0 / CERN-OHL-S-2.0", BOARD_W / 2, PI_Y + 21.0, 0.8)
board_text("5V IN: USB-C or J1 (+ left)", 21.5, 38.6, 0.8)
board_text("only ONE source at a time", 21.5, 40.1, 0.8)
# antenna connectors
for ref, (x, label) in ANT.items():
    pts, side = RF_LINES[{"J13": "RF_HF_LORA", "J14": "RF_HF_24", "J15": "RF_LF_24", "J16": "RF_LF_LORA"}[ref]]
    board_text("ANT " + label, x + side * 4.2, 21.0 if ref in ("J13", "J14") else 15.5, 0.8, angle=90)
# connector pin labels (= pin names of the device that plugs in)
for k, txt in enumerate(("3V3", "GND", "TX", "RX", "PPS")):
    board_text(txt, BOARD_W - 8.7, 26.0 - k * 2.5, 0.8)
board_text("GPS", BOARD_W - 8.7, 28.6, 0.9)
for k, txt in enumerate(("GND", "VCC", "SCL", "SDA")):
    board_text(txt, 135.5, 15.0 + k * 2.54, 0.8)
board_text("I2C 3.3V", 135.5, 11.8, 0.8)
for k, txt in enumerate(("GND", "RXD", "TXD")):
    board_text(txt, BOARD_W - 6.6, 31.0 + k * 2.54, 0.8)
board_text("CONSOLE", BOARD_W - 5.5, 39.0, 0.8)
board_text("I2C 3.3V", 21.5, 8.3, 0.8)
board_text("I2C 3.3V", 134.5, 8.3, 0.8)
board_text("I2C 3.3V", 78.0, 44.0, 0.8)
board_text("JLCJLCJLCJLC", BOARD_W / 2, PI_Y + 24.0, 1.0, layer=pcbnew.B_SilkS)

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
