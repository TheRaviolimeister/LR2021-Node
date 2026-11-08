#!/bin/sh
# Baut die Firmware für beide ESP32 (benötigt arduino-cli mit ESP32-Core 3.1.x und RadioLib >= 7.8)
set -e
cd "$(dirname "$0")"
FQBN="esp32:esp32:esp32s3:FlashSize=4M,FlashMode=dio,PSRAM=disabled,CDCOnBoot=default"
mkdir -p bin
for R in A B; do
  arduino-cli compile --fqbn "$FQBN" --warnings all \
    --build-property "compiler.cpp.extra_flags=-DMODEM_ROLE_$R" \
    --build-property "compiler.c.extra_flags=-DMODEM_ROLE_$R" \
    $EXTRA_ARGS --output-dir "build_$R" lr2021_modem
  # komplettes Abbild ab Adresse 0x0 (Bootloader + Partitionen + Programm), ohne leeres Auffüllen
  python3 -c "import sys;d=open(sys.argv[1],'rb').read().rstrip(b'\\xff');open(sys.argv[2],'wb').write(d+b'\\xff'*(-len(d)%16))" \
    "build_$R/lr2021_modem.ino.merged.bin" "bin/lr2021_modem_$R.bin"
done
ls -la bin
