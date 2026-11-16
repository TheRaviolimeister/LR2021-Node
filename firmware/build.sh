#!/bin/sh
# Baut die Firmware für beide ESP32 (benötigt arduino-cli mit ESP32-Core 3.1.x und RadioLib >= 7.8)
# Partitionstabelle "default" (4 MB): nvs, otadata, app0/app1 je 1,25 MB (OTA), spiffs, coredump.
# Sie darf sich nicht ändern: Updates über die Modem-Verbindung schreiben nur in den freien App-Slot.
set -e
cd "$(dirname "$0")"
FQBN="esp32:esp32:esp32s3:FlashSize=4M,FlashMode=dio,PSRAM=disabled,CDCOnBoot=default,PartitionScheme=default"
mkdir -p bin
for R in A B; do
  arduino-cli compile --fqbn "$FQBN" --warnings all \
    --build-property "compiler.cpp.extra_flags=-DMODEM_ROLE_$R" \
    --build-property "compiler.c.extra_flags=-DMODEM_ROLE_$R" \
    $EXTRA_ARGS --output-dir "build_$R" lr2021_modem
  # komplettes Abbild ab Adresse 0x0 (Bootloader + Partitionen + Programm), ohne leeres Auffüllen
  python3 -c "import sys;d=open(sys.argv[1],'rb').read().rstrip(b'\\xff');open(sys.argv[2],'wb').write(d+b'\\xff'*(-len(d)%16))" \
    "build_$R/lr2021_modem.ino.merged.bin" "bin/lr2021_modem_$R.bin"
  # Prüfen: Partitionstabelle wie erwartet, Programm passt mit Reserve in jeden App-Slot,
  # das Abbild enthält das Programm unverändert an 0x10000 und die richtige Kennung
  python3 - "$R" "build_$R" "bin/lr2021_modem_$R.bin" <<'EOF'
import re, struct, sys
role, bdir, out = sys.argv[1:4]
pt = open(bdir + "/lr2021_modem.ino.partitions.bin", "rb").read()
parts = {}
for i in range(0, len(pt), 32):
    e = pt[i:i + 32]
    if e[:2] != b"\xaa\x50":
        break
    typ, sub, off, size = struct.unpack("<BBII", e[2:12])
    parts[e[12:28].rstrip(b"\0").decode()] = (typ, sub, off, size)
want = {"nvs": (1, 2, 0x9000, 0x5000), "otadata": (1, 0, 0xE000, 0x2000),
        "app0": (0, 0x10, 0x10000, 0x140000), "app1": (0, 0x11, 0x150000, 0x140000)}
for name, v in want.items():
    if parts.get(name) != v:
        sys.exit("Partitionstabelle: %s ist %s, erwartet %s" % (name, parts.get(name), v))
app = open(bdir + "/lr2021_modem.ino.bin", "rb").read()
img = open(out, "rb").read()
slot = min(parts["app0"][3], parts["app1"][3])
if len(app) > slot * 0.8:
    sys.exit("Programm %d Bytes, App-Slot %d Bytes: zu wenig Reserve" % (len(app), slot))
if img[0] != 0xE9 or img[0x8000:0x8000 + len(pt)].rstrip(b"\xff") != pt.rstrip(b"\xff") \
        or img[0x10000:0x10000 + len(app)] != app or len(img) != 0x10000 + len(app):
    sys.exit("Abbild %s passt nicht zu Bootloader/Partitionen/Programm" % out)
if app[0] != 0xE9 or struct.unpack("<H", app[12:14])[0] != 9 or app[23] != 1:
    sys.exit("Programm: Kopf unerwartet (Magic/Chip/SHA-256)")
ids = re.findall(rb"LRMODEM fw (\d+)\.(\d+)\.(\d+) role ([AB]) ", app)
if len(ids) != 1 or ids[0][3].decode() != role:
    sys.exit("Kennung im Programm falsch: %r" % ids)
print("Rolle %s: Programm %d Bytes, App-Slot %d Bytes (%.0f %% frei), Abbild %d Bytes ab 0x0, fw %s"
      % (role, len(app), slot, 100 - 100.0 * len(app) / slot, len(img), b".".join(ids[0][:3]).decode()))
EOF
done
ls -la bin
