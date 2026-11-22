#!/usr/bin/env python3
"""Plug-in 868 MHz filter module for the LR2021 Node carrier board (socket J22).

A small two-layer board with a SAW band-pass filter (868-870 MHz) and a 1x5 pin header
(GND, port 1, GND, port 2, GND, 2.54 mm). It plugs into J22 between the Core2021-HF and the
SE2435L front end. The filter is reciprocal, so the orientation of the ports does not matter;
the module only fits one way round because the pins are symmetrical anyway.

Writes filter868.kicad_pcb and ./fabrication (Gerber zip, BOM, placement file, renders).
Run inside an environment with KiCad 9 (pcbnew Python module and kicad-cli):

    python3 generate_filter.py
"""
import csv
import json
import os
import shutil
import subprocess
import sys
import zipfile

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_PCB = os.path.join(HERE, "filter868.kicad_pcb")
FAB = os.path.join(HERE, "fabrication")
LIB = "/usr/share/kicad/footprints"
MM = pcbnew.FromMM

W, H = 13.2, 9.0                   # board size
P0 = (1.52, 1.5)                   # header pin 1 (pins along +x, 2.54 mm)
SAW = (W / 2, 5.6)                 # centre of the SAW filter
LINE_W, GAP = 0.6, 0.2             # grounded coplanar line on 1.6 mm FR4: about 55 ohm (5 mm long)


def V(x, y):
    return pcbnew.VECTOR2I(MM(x), MM(y))


board = pcbnew.BOARD()
board.SetCopperLayerCount(2)
ds = board.GetDesignSettings()
ds.m_TrackMinWidth = MM(0.2)
ds.m_ViasMinSize = MM(0.6)
ds.m_MinThroughDrill = MM(0.3)
ds.m_CopperEdgeClearance = MM(0.3)
ds.m_MinClearance = MM(0.15)
ds.m_NetSettings.GetDefaultNetclass().SetClearance(MM(0.15))
ds.m_TentViasFront = ds.m_TentViasBack = True
ds.SetAuxOrigin(V(0, H))
nets = {}


def net(name):
    if name not in nets:
        n = pcbnew.NETINFO_ITEM(board, name)
        board.Add(n)
        nets[name] = n
    return nets[name]


def text(t, x, y, size=0.8, layer=pcbnew.F_SilkS, mirror=False):
    o = pcbnew.PCB_TEXT(board)
    o.SetText(t)
    o.SetPosition(V(x, y))
    o.SetLayer(layer)
    o.SetTextSize(V(size, size))
    o.SetTextThickness(MM(0.12))
    o.SetMirrored(mirror)
    board.Add(o)


# ---- SAW filter: EPCOS/Qualcomm DCC6C (3.0 x 3.0 mm), KiCad library footprint after EPCOS app note 93:
# 1.2 mm pitch, pins 1-3 left column top to bottom, 4-6 right column bottom to top;
# 2 = input, 5 = output, 1/3/4/6 = case ground (B3725 data sheet).
saw = pcbnew.FootprintLoad(os.path.join(LIB, "Filter.pretty"), "Filter_SAW_Epcos_DCC6C_3x3mm")
saw.SetReference("FL1")
saw.SetValue("B39871B3725U410")
saw.Reference().SetVisible(False)
saw.Value().SetVisible(False)
saw.SetPosition(V(*SAW))
board.Add(saw)

# ---- pin header 1x5 (pins down into the socket on the carrier) ----
hdr = pcbnew.FootprintLoad(os.path.join(LIB, "Connector_PinHeader_2.54mm.pretty"), "PinHeader_1x05_P2.54mm_Vertical")
hdr.SetReference("J1")
hdr.SetValue("1x5 2.54")
hdr.Reference().SetVisible(False)
hdr.Value().SetVisible(False)
hdr.SetPosition(V(*P0))
hdr.SetOrientationDegrees(90)                     # pins along +x
board.Add(hdr)

# nets
gnd, p1, p2 = net("GND"), net("PORT1"), net("PORT2")
for p in saw.Pads():
    p.SetNet({"2": p1, "5": p2}.get(p.GetNumber(), gnd))
    if p.GetNet() == gnd:
        p.SetLocalZoneConnection(pcbnew.ZONE_CONNECTION_FULL)
for p in hdr.Pads():
    p.SetNet({"2": p1, "4": p2}.get(p.GetNumber(), gnd))
    if p.GetNet() == gnd:
        p.SetLocalZoneConnection(pcbnew.ZONE_CONNECTION_FULL)


def pad_pos(fp, num):
    for p in fp.Pads():
        if p.GetNumber() == str(num):
            c = p.GetPosition()
            return (pcbnew.ToMM(c.x), pcbnew.ToMM(c.y))


def track(n, w, a, b):
    t = pcbnew.PCB_TRACK(board)
    t.SetStart(V(*a))
    t.SetEnd(V(*b))
    t.SetWidth(MM(w))
    t.SetLayer(pcbnew.F_Cu)
    t.SetNet(n)
    board.Add(t)


def via(x, y):
    v = pcbnew.PCB_VIA(board)
    v.SetPosition(V(x, y))
    v.SetWidth(MM(0.6))
    v.SetDrill(MM(0.3))
    v.SetNet(gnd)
    board.Add(v)


# lines: header pin 2 -> SAW pin 2, header pin 4 -> SAW pin 5 (straight down, then into the pad)
for hp, sp, n in ((2, 2, p1), (4, 5, p2)):
    a = pad_pos(hdr, hp)
    b = pad_pos(saw, sp)
    knee = (a[0], b[1])
    track(n, LINE_W, a, knee)
    track(n, LINE_W, knee, b)
# ground: two vias between the pad columns, the ground pads tied to them, vias along the lines and
# in the corners
sx, sy = SAW
for x, y in ((sx, sy - 0.6), (sx, sy + 0.6), (sx - 1.4, sy - 2.6), (sx + 1.4, sy - 2.6),
             (P0[0] + 2.54 - 1.25, 4.3), (P0[0] + 7.62 + 1.25, 4.3),
             (0.8, 8.2), (W - 0.8, 8.2), (0.8, 4.6), (W - 0.8, 4.6)):
    via(x, y)
for num, (vx, vy) in ((3, (sx, sy + 0.6)), (4, (sx, sy + 0.6)), (6, (sx, sy - 0.6)), (1, (sx, sy - 0.6))):
    track(gnd, 0.4, pad_pos(saw, num), (vx, vy))

# outline
for a, b in (((0, 0), (W, 0)), ((W, 0), (W, H)), ((W, H), (0, H)), ((0, H), (0, 0))):
    s = pcbnew.PCB_SHAPE(board)
    s.SetShape(pcbnew.SHAPE_T_SEGMENT)
    s.SetStart(V(*a))
    s.SetEnd(V(*b))
    s.SetLayer(pcbnew.Edge_Cuts)
    s.SetWidth(MM(0.1))
    board.Add(s)
# ground planes (top keeps 0.25 mm to the lines = coplanar gap)
for layer in (pcbnew.F_Cu, pcbnew.B_Cu):
    z = pcbnew.ZONE(board)
    z.SetLayer(layer)
    z.SetNet(gnd)
    ol = z.Outline()
    ol.NewOutline()
    for x, y in ((0.2, 0.2), (W - 0.2, 0.2), (W - 0.2, H - 0.2), (0.2, H - 0.2)):
        ol.Append(MM(x), MM(y))
    z.SetLocalClearance(MM(GAP))
    z.SetMinThickness(MM(0.2))
    z.SetPadConnection(pcbnew.ZONE_CONNECTION_FULL)
    z.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
    board.Add(z)

text("868-870 MHz", W / 2, 8.2, 0.8)          # pass band, readable when plugged in
text("868-870 MHz SAW", W / 2, 6.9, 0.8, pcbnew.B_SilkS, mirror=True)
text("LR2021 Node", W / 2, 8.1, 0.8, pcbnew.B_SilkS, mirror=True)
board.Save(OUT_PCB)
b2 = pcbnew.LoadBoard(OUT_PCB)
pcbnew.ZONE_FILLER(b2).Fill(b2.Zones())
b2.Save(OUT_PCB)
print("saved", OUT_PCB)


# ---- manufacturing files ----
def run(*cmd):
    print("$", " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode not in (0, 5):
        print(r.stdout, r.stderr)
        sys.exit(r.returncode)


shutil.rmtree(FAB, ignore_errors=True)
gerb = os.path.join(FAB, "gerber")
os.makedirs(gerb)
run("kicad-cli", "pcb", "drc", "--format", "json", "--units", "mm", "-o", os.path.join(FAB, "drc.json"), OUT_PCB)
drc = json.load(open(os.path.join(FAB, "drc.json")))
errs = [v for v in drc.get("violations", []) if v.get("severity") == "error" and v["type"] != "lib_footprint_issues"]
unc = drc.get("unconnected_items", [])
print(f"DRC: {len(errs)} errors, {len(unc)} unconnected", sorted({v['type'] for v in errs}))
run("kicad-cli", "pcb", "export", "gerbers", "-o", gerb + "/", "-l",
    "F.Cu,B.Cu,F.Paste,F.Silkscreen,B.Silkscreen,F.Mask,B.Mask,Edge.Cuts", "--subtract-soldermask", "--no-x2", OUT_PCB)
run("kicad-cli", "pcb", "export", "drill", "-o", gerb + "/", "--format", "excellon", "--excellon-separate-th", OUT_PCB)
with zipfile.ZipFile(os.path.join(FAB, "filter868-gerber.zip"), "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted(os.listdir(gerb)):
        z.write(os.path.join(gerb, f), f)
shutil.rmtree(gerb)
with open(os.path.join(FAB, "bom.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["Comment", "Designator", "Footprint", "LCSC Part #"])
    w.writerow(["B39871B3725U410 (SAW 869 MHz, 868-870 MHz)", "FL1", "Filter_SAW_Epcos_DCC6C_3x3mm", "C2651001"])
with open(os.path.join(FAB, "cpl.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["Designator", "Mid X", "Mid Y", "Layer", "Rotation"])
    w.writerow(["FL1", f"{SAW[0]:.3f}mm", f"{H - SAW[1]:.3f}mm", "Top", "0"])
with open(os.path.join(FAB, "hand-solder.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["Qty", "Designator", "Part", "Footprint", "LCSC Part #"])
    w.writerow([1, "J1", "male pin header 1x5, 2.54 mm (pins down, short side up)", "PinHeader_1x05_P2.54mm_Vertical", ""])
for side in ("top", "bottom"):
    run("kicad-cli", "pcb", "render", "--side", side, "--width", "800", "--height", "600", "--quality", "high",
        "--background", "opaque", "-o", os.path.join(FAB, f"{side}.png"), OUT_PCB)
print("done:", FAB)
sys.exit(1 if errs or unc else 0)
