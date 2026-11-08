# Parts list

Everything needed for one LR2021 Node. The parts are available from the usual electronics suppliers;
the names are chosen so you can search for them directly.

## Main parts

| Qty | Part | Note |
|---:|---|---|
| 1 | **Orange Pi Zero 2W**, 1 GB RAM (Allwinner H618) | the node's computer |
| 1 | Orange Pi Zero 2W **expansion board** | optional: 2× USB-A, LAN, audio |
| 2 | **ESP32-S3 DevKitC-1** (e.g. N16R8, N8R2) | radio modem A and B, any S3 variant works |
| 1 | **Waveshare Core2021-HF** (Semtech LR2021, 850–930 MHz + 2.4 GHz) | radio module for ESP32 A |
| 1 | **Waveshare Core2021-LF** (Semtech LR2021, 410–510 MHz + 2.4 GHz) | radio module for ESP32 B |
| 1 | **GPS module L76X** (Waveshare L76X GPS HAT or L76X module) | position, 9600 baud |
| 1 | **CP2102 USB-to-serial adapter** (USB-C or Micro-USB) | serial console, connection to the PC app |
| 1 | microSD card, at least 16 GB, class A1 | operating system of the node |

## Antennas

| Qty | Part | Note |
|---:|---|---|
| 1 | 868 MHz antenna | for the Core2021-HF, connector matching the module (pigtail if needed) |
| 1 | 433 MHz antenna (70 cm) | for the Core2021-LF |
| 2 | 2.4 GHz antenna | optional; without antennas 2.4 GHz stays locked |

**Never transmit without an antenna.** The firmware only transmits on command; the 2.4 GHz bands are
locked by default.

## Power supply (one of the two)

| Qty | Part | Note |
|---:|---|---|
| 1 | USB-C power supply 5 V / 3 A | simplest option, directly into the Orange Pi |
| 1 | 4×18650 battery shield with 5 V output + 4 × 18650 cells | portable; connected via J1 to the 5 V rail |

## Assembly material

| Qty | Part | Note |
|---:|---|---|
| 1 | perfboard 100 × 150 mm, 2.54 mm pitch | carrier for everything |
| 1 | female header 2×20, 2.54 mm | socket for the Orange Pi |
| 4 | female header 1×22, 2.54 mm | sockets for the two ESP32 |
| 2 | female headers matching the Core2021 modules | sockets for the LR2021 |
| 1 | JST-XH 2-pin (plug + socket) | J1 power |
| 1 | JST-XH 5-pin (plug + socket) | J2 GPS |
| – | enamelled copper wire 0.2–0.3 mm or hook-up wire AWG 28–30 | wiring |
| – | standoffs M2.5 / M3 | mounting |

## Tools

Soldering iron (fine tip), solder, multimeter, side cutters. For the software a PC with Windows (or
Linux) and – only for building the SD card image – WSL2 with Ubuntu.
