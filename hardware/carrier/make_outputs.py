#!/usr/bin/env python3
"""Design rule check and manufacturing files for the LR2021 Node carrier board.

Writes into ./fabrication:
  lr2021-carrier-gerber.zip   Gerber + drill files (upload this to the PCB manufacturer)
  bom.csv                     parts for SMD assembly (JLCPCB format, LCSC part numbers)
  cpl.csv                     placement file for SMD assembly (JLCPCB format)
  hand-solder.csv             through-hole parts you solder yourself
  top.png / bottom.png        3D renders
  drc.json                    design rule check report
"""
import csv
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
PCB = os.path.join(HERE, "lr2021-carrier.kicad_pcb")
OUT = os.path.join(HERE, "fabrication")
GERB = os.path.join(OUT, "gerber")

# rotation offsets between KiCad footprints and the JLCPCB part library
JLC_ROT = [(r"^SOT-23", 180)]


def run(*cmd):
    print("$", " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode not in (0, 5):  # kicad-cli drc returns 5 when violations exist
        print(r.stdout, r.stderr)
        sys.exit(r.returncode)
    return r


shutil.rmtree(OUT, ignore_errors=True)
os.makedirs(GERB)

# design rule check
run("kicad-cli", "pcb", "drc", "--format", "json", "--units", "mm", "--all-track-errors",
    "-o", os.path.join(OUT, "drc.json"), PCB)
drc = json.load(open(os.path.join(OUT, "drc.json")))
viol = [v for v in drc.get("violations", []) if v.get("severity") == "error"]
unconn = drc.get("unconnected_items", [])
print(f"DRC: {len(viol)} errors, {len(unconn)} unconnected")
kinds = {}
for v in viol:
    kinds[v["type"]] = kinds.get(v["type"], 0) + 1
print("  ", kinds)
# ground pads the planes did not reach: generate_board.py links them with a track in the next run
gnd = sorted({m.group(2) + "." + m.group(1) for u in unconn for it in u.get("items", [])
              for m in [re.search(r"pad (\S+) \[GND\] of (\S+)", it.get("description", ""))] if m})
if any(all(it.get("description", "").startswith("Zone [GND]") for it in u.get("items", [])) for u in unconn):
    # a piece of a ground plane is cut off: link the ground pads that sit on the small pieces
    b_ = pcbnew.LoadBoard(PCB)
    for z in b_.Zones():
        L = pcbnew.B_Cu                      # the bottom plane should be one piece
        if not z.IsOnLayer(L):
            continue
        ps = z.GetFilledPolysList(L)
        areas = sorted(range(ps.OutlineCount()), key=lambda k: -ps.Outline(k).Area())
        for k in areas[1:]:
            poly = ps.Outline(k)
            for fp in b_.GetFootprints():
                for p in fp.Pads():
                    if p.GetNetname() == "GND" and p.IsOnLayer(L) and poly.PointInside(p.GetPosition()):
                        gnd.append(fp.GetReference() + "." + p.GetNumber())
    gnd = sorted(set(gnd))
if gnd:
    old =json.load(open(os.path.join(HERE, ".gnd_links.json"))) if os.path.exists(os.path.join(HERE, ".gnd_links.json")) else []
    json.dump(sorted(set(old) | set(gnd)), open(os.path.join(HERE, ".gnd_links.json"), "w"))
    print("   ground pads without plane connection:", gnd)

# Gerber and drill
layers = "F.Cu,B.Cu,F.Paste,F.Silkscreen,B.Silkscreen,F.Mask,B.Mask,Edge.Cuts"
run("kicad-cli", "pcb", "export", "gerbers", "-o", GERB + "/", "-l", layers,
    "--subtract-soldermask", "--no-x2", PCB)
run("kicad-cli", "pcb", "export", "drill", "-o", GERB + "/", "--format", "excellon",
    "--excellon-separate-th", "--generate-map", "--map-format", "gerberx2", PCB)
zpath = os.path.join(OUT, "lr2021-carrier-gerber.zip")
with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted(os.listdir(GERB)):
        z.write(os.path.join(GERB, f), f)
shutil.rmtree(GERB)

# BOM / CPL
board = pcbnew.LoadBoard(PCB)
parts = json.load(open(os.path.join(HERE, ".parts.json")))
aux = board.GetDesignSettings().GetAuxOrigin()
groups = {}
cpl = []
hand = {}
for fp in board.GetFootprints():
    ref = fp.GetReference()
    if ref not in parts:
        continue
    p = parts[ref]
    name = fp.GetFPID().GetLibItemName().wx_str()
    if p["value"] == "DNP":      # optional pi-network places, not fitted
        continue
    if not p["assemble"]:
        hand.setdefault((p["value"], name, p["lcsc"]), []).append(ref)
        continue
    groups.setdefault((p["value"], name, p["lcsc"]), []).append(ref)
    pos = fp.GetPosition()
    x = pcbnew.ToMM(pos.x - aux.x)
    y = -pcbnew.ToMM(pos.y - aux.y)
    rot = fp.GetOrientationDegrees()
    for pat, off in JLC_ROT:
        if re.match(pat, name):
            rot += off
    cpl.append((ref, f"{x:.3f}mm", f"{y:.3f}mm", "Top", f"{rot % 360:.0f}"))


def natkey(r):
    m = re.match(r"([A-Z]+)(\d+)", r)
    return (m.group(1), int(m.group(2))) if m else (r, 0)


with open(os.path.join(OUT, "bom.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["Comment", "Designator", "Footprint", "LCSC Part #"])
    for (val, name, lcsc), refs in sorted(groups.items(), key=lambda kv: natkey(sorted(kv[1], key=natkey)[0])):
        w.writerow([val, ",".join(sorted(refs, key=natkey)), name, lcsc])
with open(os.path.join(OUT, "cpl.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["Designator", "Mid X", "Mid Y", "Layer", "Rotation"])
    for row in sorted(cpl, key=lambda r: natkey(r[0])):
        w.writerow(row)
with open(os.path.join(OUT, "hand-solder.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["Qty", "Designator", "Part", "Footprint", "LCSC Part #"])
    extra = {
        "U1": "2x female header 1x22, 2.54 mm",
        "U2": "2x female header 1x22, 2.54 mm",
        "U3": "2x female header 1x8, 2.54 mm",
        "U4": "2x female header 1x8, 2.54 mm",
        "U5": "female header 2x20, 2.54 mm",
        "J22": "female header 1x5, 2.54 mm (868 MHz filter module, see hardware/filter868)",
    }
    for (val, name, lcsc), refs in sorted(hand.items(), key=lambda kv: natkey(kv[1][0])):
        refs = sorted(refs, key=natkey)
        part = " / ".join(sorted({extra.get(r, val) for r in refs}))
        w.writerow([len(refs), ",".join(refs), part, name, lcsc])

# renders
for side in ("top", "bottom"):
    run("kicad-cli", "pcb", "render", "--side", side, "--width", "1600", "--height", "1600",
        "--quality", "high", "--background", "opaque", "-o", os.path.join(OUT, f"{side}.png"), PCB)
run("kicad-cli", "pcb", "export", "svg", "-l", "F.Cu,B.Cu,F.Silkscreen,Edge.Cuts", "--mode-single",
    "--fit-page-to-board", "--exclude-drawing-sheet", "-o", os.path.join(OUT, "layout.svg"), PCB)
print("done:", OUT)
sys.exit(1 if viol or unconn else 0)
