# LR2021 Node – carrier board

A 100 × 100 mm two-layer PCB that replaces the perfboard and the point-to-point wiring. All modules
stay pluggable: the Orange Pi Zero 2W, both ESP32-S3 DevKitC-1 and both Core2021 modules sit in
female headers. The small SMD parts can be assembled by the PCB manufacturer.

![Top](fabrication/top.png)

> Revision 1.0 has not been manufactured yet. Before ordering, print `fabrication/layout.svg` at
> 100 % and check the header positions against your own modules.

## What the board adds compared to the perfboard

- **One protected 5 V input:** USB-C (power only) or JST-XH J1 for the 18650 battery shield, with
  reverse-polarity protection (2 × P-MOSFET), 3 A resettable fuse, TVS diode and a power LED.
- **No back-feeding:** each ESP32 gets its 5 V through a Schottky diode, so a PC on the ESP32's USB
  port cannot feed the node's 5 V rail. All UART lines between the modules and to the console
  have 1 kΩ series resistors, so nothing is powered through the data lines when only one side
  is switched on. The console connector has no supply pin.
- **ESP32 reset and boot from the Orange Pi:** the Pi can pull EN and GPIO0 of each ESP32 low via
  a MOSFET (Pi pins 29/31 = EN/GPIO0 of ESP32 A, pins 32/33 = EN/GPIO0 of ESP32 B; high = pulled
  low). Pull-down resistors keep the ESP32 running while the Pi boots.
- **LR2021 DIO7 and DIO8** are connected to GPIO8 and GPIO9 of both ESP32 (not used by the
  current firmware, reserved).
- Decoupling capacitors at both radio modules, GPS connector with PPS, I²C connector for a display,
  ground planes on both layers.

## Ordering (e.g. JLCPCB)

1. Upload `fabrication/lr2021-carrier-gerber.zip`. Settings: 2 layers, 1.6 mm, 1 oz copper,
   any colour, HASL or ENIG.
2. For SMD assembly: enable "PCB Assembly", top side, upload `fabrication/bom.csv` and
   `fabrication/cpl.csv`. Check the parts preview: diodes (D1–D4) and transistors (Q1–Q6) must
   match the orientation marks on the board; correct the rotation there if needed.
3. The through-hole parts are soldered by hand, see `fabrication/hand-solder.csv`.

## Assembly

| Position | Part | Note |
|---|---|---|
| U1 / U2 | 2 × female header 1×22 each | ESP32 A / B. The left row has two positions: **22.86 mm** (original Espressif DevKitC-1) and **25.4 mm** (many N16R8 boards). Measure the distance between the pin rows of your board and solder the header into the matching row. USB connectors face the board edge. |
| U3 | 2 × female header 1×8 | Core2021-**HF** (868 MHz) |
| U4 | 2 × female header 1×8 | Core2021-**LF** (433 MHz) |
| U5 | female header 2×20 | Orange Pi Zero 2W: solder the 2×20 male header to the **underside** of the Pi, then plug it in component side up; the ports face the lower board edge |
| J1 | JST-XH 2-pin | 5 V input from the battery shield (+ marked) |
| J2 | JST-XH 5-pin | GPS: 3V3, GND, TX, RX, PPS – labels = pins of the GPS module (GPS TX to “TX”) |
| J3 | pin header 1×3 | console: GND, RXD, TXD – labels = pins of the USB serial adapter (adapter RXD to “RXD”); no supply pin |
| J4 | pin header 1×4 | I²C display: GND, VCC (3.3 V), SCL, SDA |

**Only one 5 V source at a time:** USB-C on the board, J1, or the Pi's own USB-C. The radio
modules connect to their antennas with IPEX pigtails – never transmit without an antenna.

## Signals

| Signal | Orange Pi pin | ESP32 / module |
|---|---|---|
| UART3 TX / RX (500000 Bd) | 28 / 27 | ESP32 A GPIO1 / GPIO2 |
| UART4 TX / RX (500000 Bd) | 7 / 16 | ESP32 B GPIO1 / GPIO2 |
| UART5 TX / RX (9600 Bd) | 11 / 13 | GPS RX / TX, PPS on pin 15 |
| UART0 TX / RX (console) | 8 / 10 | J3 |
| I²C SDA / SCL | 3 / 5 | J4 |
| EN / GPIO0 ESP32 A | 29 / 31 | via MOSFET, high = low on the ESP32 |
| EN / GPIO0 ESP32 B | 32 / 33 | via MOSFET, high = low on the ESP32 |

ESP32 ↔ LR2021 as in [assembly.md](../../docs/hardware/assembly.md), plus DIO7 → GPIO8 and
DIO8 → GPIO9.

## Files

| File | Content |
|---|---|
| `generate_board.py` | generates the complete board (footprints, placement, nets, routing, ground planes) |
| `make_outputs.py` | design rule check, Gerber/drill, BOM, placement, renders |
| `lr2021-carrier.kicad_pcb` | the KiCad 9 board – can be opened and edited in KiCad |
| `netlist.json` | all connections |
| `fabrication/` | files for ordering and pictures |

Rebuild (Linux or WSL with KiCad 9, `python3-numpy`, `python3-scipy`):

```
python3 generate_board.py
python3 make_outputs.py
```
