# LR2021 Node – carrier board

A 172 × 106 mm two-layer PCB that replaces the perfboard and the point-to-point wiring. All modules
stay pluggable: the Orange Pi Zero 2W, both ESP32-S3 DevKitC-1 and both Core2021 modules sit in
female headers with generous space between them. The four antenna connectors are soldered to the
board, and the small SMD parts can be assembled by the PCB manufacturer. The 868 MHz path has a
1 W front end (power amplifier, low-noise amplifier with bypass) and a socket for a plug-in filter.

![Top](fabrication/top.png)

> Revision 1.3 has not been manufactured yet. Before ordering, print `fabrication/layout.svg` at
> 100 % and check the header positions against your own modules.

## Layout

```
 top edge:                 [868 LoRa]  [2.4G HF]  I2C I2C  [2.4G LF]  [433 LoRa]   I2C I2C I2C
             USB-C / J1  868 PA/LNA  Core2021-HF               Core2021-LF
             power input  filter      (both modules at the same height, mirrored)
                                    I2C  I2C  I2C  I2C  I2C
             ESP32 A            I2C header                                     ESP32 B
             (USB at the        I2C header  CONSOLE  GPS                       (USB at the
              bottom edge)  USB  Orange Pi Zero 2W (ports at the bottom edge)   bottom edge)
                         console
```

The layout is mirror-symmetric about the vertical centre line: both radio modules sit at the same
height, both ESP32 at the same distance from the side edges. The connectors for the console
adapter, GPS and I²C sit in the middle, directly above the Orange Pi pins they belong to. The USB
console (USB-C, CH340C, TX/RX LEDs) sits between ESP32 A and the Orange Pi at the bottom edge.
Signals run on the top layer; the bottom layer is a ground plane that is only interrupted by short
crossings (mainly where the I²C bus branches to the sockets). The bus between each ESP32 and its
radio module is routed without crossings: the lines of ESP32 A run in parallel along the left
edge and over the top end of its socket, the 5 V rail runs along the left edge and under the USB end
of ESP32 A and continues under the Orange Pi. The USB-C receptacle, the ESD protection and the
USB data lines have a fixed fan-out (0.5 mm pin pitch).

## Features

- **Four SMA antenna connectors (90°, through hole) on the top edge:** 868 MHz LoRa on the left,
  433 MHz LoRa on the right, the two 2.4 GHz connectors in the middle.
  - **RF lines:** each module pin is connected to its connector by a 50 Ω line (grounded
    coplanar waveguide: 1.55 mm track, 0.3 mm gap, solid ground underneath, ground via fence on
    both sides; calculated for the standard 1.6 mm FR4 two-layer stack). No other signal crosses
    or runs underneath an RF line. The 433 MHz line is 15 mm long; on the 868 MHz side the module
    feeds the filter socket and the front end, whose output sits 10 mm below its connector. A
    matched line of this length does not radiate and loses well below 0.2 dB.
  - **Filter places:** the RF lines have a π network close to the connector: the series 0 Ω
    resistor is fitted, the shunt places (0603) stay empty. A low-pass or matching network can be
    added later (see "RF filters" below). On the 868 MHz line the module-side shunt is the fitted
    2.7 pF capacitor of the front end's antenna low-pass.
- **868 MHz front end (U8, Skyworks SE2435L):** see the section below – up to +30 dBm (1 W) at the
  connector, a low-noise amplifier with bypass that the firmware switches by the measured noise
  floor, and the plug-in filter socket J22.
- **Ten Qwiic / STEMMA QT sockets plus two 4-pin headers for I²C peripherals** (display, buttons,
  switches, sensors, I/O expanders). All of them are on the same bus: Orange Pi pins 3 (SDA) and
  5 (SCL), 4.7 kΩ pull-ups to 3.3 V. **3.3 V only:** do not connect modules that pull SDA/SCL up
  to 5 V.
- **One protected 5 V input:** USB-C (power only) or JST-XH J1 for the 18650 battery shield, with
  reverse-polarity protection (2 × P-MOSFET), 3 A resettable fuse, TVS diode and a power LED.
- **No back-feeding:** each ESP32 gets its 5 V through a Schottky diode, so a PC on the ESP32's USB
  port cannot feed the node's 5 V rail. All UART lines between the modules and to the console
  have 1 kΩ series resistors, so nothing is powered through the data lines when only one side
  is switched on. The console connector has no supply pin.
- **ESP32 reset and boot from the Orange Pi:** the Pi can pull EN and GPIO0 of each ESP32 low via
  a MOSFET (Pi pins 29/31 = EN/GPIO0 of ESP32 A, pins 32/33 = EN/GPIO0 of ESP32 B; high = pulled
  low). 10 kΩ pull-down resistors keep the MOSFETs off (ESP32 running) while the Pi boots or the
  Pi pins are not configured.
- **LR2021 DIO7 and DIO8** are connected to GPIO8 and GPIO9 of both ESP32 (not used by the
  current firmware, reserved).
- **USB console on the board:** USB-C J21 ("USB CONSOLE") with a CH340C USB serial converter and
  USBLC6-2SC6 ESD protection. It is the Orange Pi's debug console (UART0, 115200 Bd) and the
  "Node cable" connection of the app – one USB-C cable from the PC is enough. Two LEDs show the
  traffic: **TX** (red) = PC to node, **RX** (green) = node to PC.
  - The CH340C runs from the node's 3.3 V, the 5 V of the PC is not used at all (WCH self-powered
    mode). No current can flow between PC and node through the data lines, and the PC cannot feed
    the node. The COM port therefore only appears while the node is switched on.
  - Windows 10/11 installs the CH340 driver automatically (otherwise: WCH "CH341SER"); Linux and
    Android (USB-OTG) support it out of the box. The app recognises it as the node console.
- **Console adapter connector:** J3 (GND, RXD, TXD) for an external USB serial adapter such as the
  CP2102 module, in parallel to the on-board converter. Use only one of them at a time. Connect only
  GND, RXD and TXD of the adapter, not its 3.3 V / 5 V pin.
- Decoupling capacitors at both radio modules, an extra 22 µF at the Orange Pi's 5 V pins, GPS
  connector with PPS, ground planes on both layers.
- **Mounting holes:** M3 in the two top corners and two under the USB ends of the ESP32 sockets
  (mount the board before plugging in the ESP32). Orange Pi pin 6 (GND) is not connected on the
  carrier – it is connected to the other GND pins inside the Pi.

## 868 MHz front end

```
 Core2021-HF ── J22 filter socket ── SE2435L TR ─┬─ LNA (16 dB) / bypass ──┐
  (LORA_ANT)     (plug-in SAW)                   └─ PA (26 dB, up to 1 W) ─┴─ ANT1 ── low-pass ── SMA 868
```

- **U8 Skyworks SE2435L** (860–930 MHz front-end module): power amplifier up to +30 dBm, low-noise
  amplifier (16 dB gain, 2 dB noise figure) with bypass, transmit/receive switch. The output match
  (L2, C30, C31, L1), the harmonic traps (L7/C32 at the PA output, L9/C33 at the antenna side), the
  antenna low-pass (L8, L6, C9) and the supply decoupling follow the Skyworks SE2435L-EK5 evaluation
  board (+30 dBm, 868–930 MHz, ETSI/FCC). The values are a starting point: on a two-layer board the
  output match may need a small correction for the very last dB – check with a power meter.
- **Supply:** U9 TLV75901 (1 A LDO) makes 4.68 V for the front end from the 5 V rail, behind a
  ferrite bead (FB1). At +30 dBm the front end draws about 0.55 A while transmitting; the 5 V
  source has to deliver this on top of the rest of the node. The exposed pad of U8 has nine vias
  into the bottom ground plane as a heat sink.
- **Filter socket J22** (1×5 female header: GND, port 1, GND, port 2, GND): sits between the radio
  module and the front end. When receiving, the filter is behind the LNA, so its loss costs almost
  no sensitivity, and strong signals outside the band (e.g. LTE 800 directly below 868 MHz) never
  reach the LR2021. When transmitting, only the drive level of a few mW passes the filter, so a small
  SAW filter is enough. The filter module is described in [hardware/filter868](../filter868); for a
  different band (another radio module, 915 MHz, …) plug in a module with a matching filter.
  **Without a filter module the 868 MHz path is open:** bridge pin 2 and pin 4 of J22 with a short
  wire instead.
- **Control from ESP32 A:** GPIO42 = CSD (front end on), GPIO41 = CPS (LNA on / bypass),
  GPIO40 = CTX (transmit via the PA), each through 1 kΩ. The three lines run in parallel next to the
  filter socket and cross the bus of ESP32 A once, with one via each, on the bottom layer. A 10 kΩ pull-down on CSD keeps the front end
  switched off while the ESP32 starts; the firmware detects the front end by this pull-down.
- **Firmware (1.1.0 or newer required):**
  - The transmit power set by the app is the power at the connector. The firmware converts it into
    the LR2021 drive level: from 14 dBm upwards the signal goes through the PA, below that through
    the bypass (up to about 3 dBm; requests between 4 and 13 dBm are sent with these 3 dBm, never more).
  - **The legal limits are enforced in the firmware**, whatever the app asks for: 27 dBm (500 mW ERP)
    in 869.40–869.65 MHz (Meshtastic EU_868, MeshCore), 14 dBm (25 mW ERP) everywhere else; both
    assume an antenna gain of up to 2.15 dBi. The hardware alone could do more (+30 dBm). At the band
    edges the firmware allows 40 kHz for the crystal correction of the app (the frequency it programs
    is offset by the measured crystal error, the transmitted one is not).
  - **LNA automatic (default):** every 5 minutes the firmware measures the noise floor with and
    without the LNA. If the receiver's own noise limits the sensitivity (quiet site), the LNA stays
    on; if the noise from outside dominates (city, a transmitter nearby), the LNA would not improve
    anything and only make the receiver easier to overload – then it switches to bypass. The mode
    (automatic / on / off) and the measured noise floor are shown in the app (Radio → Modem).
- **Never flash firmware older than 1.1.0 onto ESP32 A on this board.** Older firmware does not
  know the front end and could drive its input (max. +10 dBm) with up to +22 dBm.

## RF filters

- **868 MHz:** plug-in SAW filter (J22, see above); the front end itself has a low-pass with two
  harmonic traps at its output. An external cavity filter on the SMA connector is still possible
  (needs to be rated for 1 W).
- **433 MHz:** no filter fitted. The SMD filters that can be assembled are made for a single channel
  and are not rated for the transmit power; against strong signals next to the band use an external
  cavity filter on the SMA connector.
- **2.4 GHz:** no filter. An LTCC band-pass filter (e.g. Murata LFB182G45SG9B740, 0.7 dB, 500 mW)
  would fit, but it passes 2400–2500 MHz only and would cut off the 13 cm amateur band below
  2400 MHz.
- The π networks allow a low-pass filter for transmitter harmonics if a measurement ever shows the
  need (3rd order Butterworth, 50 Ω: 433 MHz: 5.6 pF – 27 nH – 5.6 pF; C0G capacitors, high-Q
  wire-wound inductors).

## Checks of the design

`check_board.py` and the design rule check cover:

- every connection against the pin names of the modules and parts (ESP32-S3-DevKitC-1, Core2021,
  Orange Pi Zero 2W header from the vendor's pin table, firmware pin numbers, CH340C, USBLC6-2SC6,
  USB-C receptacle, MOSFETs, diodes, SE2435L, TLV75901 – all taken from the data sheets), including
  the complete topology of the front end (match, traps, low-pass, supply feeds, control lines) and
  its supply voltage (4.68 V, recommended 4.0–4.8 V);
- no net with only one connection, no short, all nets connected; in addition to the design rule check
  `check_board.py` compares every piece of copper (tracks, vias, pads, planes) with every other one of a
  different net and reports anything touching or closer than 0.15 mm; minimum distance between parts
  (0.25 mm between the outlines; small passives and the front-end chips may touch outlines, which
  still leaves at least 0.5 mm between the bodies);
- RF lines: 48.5–51.9 Ω for the JLCPCB 1.6 mm stack-up (εr 4.2–4.8), ground plane continuous under
  and beside the lines (gaps only at the connector and module pins), via fence ≤ λ/40, no other
  track closer than 2.4 mm;
- supply: 5 V path to the Orange Pi 58 mΩ (≈ 0.09 V at 1.5 A), 1.6 mm wide.

## Radio modules: antenna signal on the pins

The Core2021 has an IPEX socket and, in parallel, the antenna signal on pin 1 (2.4 GHz) and
pin 16 (LoRa) – but only if the 0 Ω resistors R2 (2.4 GHz) and R3 (LoRa) next to the IPEX
sockets on the module are fitted. Check it with a multimeter: pin 16 to the centre contact of the
LoRa IPEX socket, and pin 1 to the centre contact of the 2.4 GHz socket, must read about 0 Ω. If
not, bridge R2/R3 with a 0402 0 Ω resistor or a solder bridge. Leave the IPEX sockets empty.

## Ordering (e.g. JLCPCB)

1. Upload `fabrication/lr2021-carrier-gerber.zip`. Settings: 2 layers, **1.6 mm**, 1 oz copper,
   FR4, any colour, HASL or ENIG. (The RF line width is calculated for this stack-up.)
2. For assembly: enable "PCB Assembly", top side, upload `fabrication/bom.csv` and
   `fabrication/cpl.csv`. The SMA connectors are through-hole parts – choose the option that
   includes through-hole assembly, or solder them yourself. Check the parts preview: diodes
   (D1–D4), transistors (Q1–Q6), the front end U8 and its LDO U9 (pin 1 mark), U6/U7, the Qwiic
   sockets and the SMA connectors must match the marks on the board; correct the rotation there if
   needed.
3. The remaining through-hole parts are soldered by hand, see `fabrication/hand-solder.csv`.

## Assembly

| Position | Part | Note |
|---|---|---|
| U1 / U2 | 2 × female header 1×22 each | ESP32 A / B, USB connectors at the bottom edge. The inner row has two positions: **22.86 mm** (original Espressif DevKitC-1) and **25.4 mm** (many N16R8 boards). Measure the distance between the pin rows of your board and solder the header into the matching row. |
| U3 | 2 × female header 1×8 | Core2021-**HF** (868 MHz), IPEX sockets pointing down |
| U4 | 2 × female header 1×8 | Core2021-**LF** (433 MHz), IPEX sockets pointing up |
| U5 | female header 2×20 | Orange Pi Zero 2W: solder the 2×20 male header to the **underside** of the Pi, then plug it in component side up; the ports face the bottom edge |
| J13–J16 | SMA jack 90°, through hole | antennas: J13 868 MHz, J14 2.4 GHz (HF), J15 2.4 GHz (LF), J16 433 MHz |
| J1 | JST-XH 2-pin | 5 V input from the battery shield (+ on the left) |
| J2 | JST-XH 5-pin | GPS: 3V3, GND, TX, RX, PPS – labels = pins of the GPS module (GPS TX to “TX”) |
| J3 | pin header 1×3 | console adapter (optional, e.g. CP2102): GND, RXD, TXD – labels = pins of the adapter (adapter RXD to “RXD”); no supply pin |
| J21 | USB-C (assembled) | USB console, see above |
| J22 | female header 1×5 | 868 MHz filter module ([hardware/filter868](../filter868)); without a module bridge pin 2 and pin 4 |
| J4, J12 | pin header 1×4 | I²C: GND, VCC (3.3 V), SCL, SDA |
| J6–J11, J17–J20 | JST SH 4-pin (Qwiic) | I²C: GND, 3.3 V, SDA, SCL (assembled) |

**Only one 5 V source at a time:** USB-C on the board, J1, or the Pi's own USB-C. Never transmit
without an antenna on the connector of the active band.

## Signals

| Signal | Orange Pi pin | ESP32 / module |
|---|---|---|
| UART4 TX / RX (500000 Bd) | 7 / 16 | ESP32 A GPIO1 / GPIO2 |
| UART3 TX / RX (500000 Bd) | 28 / 27 | ESP32 B GPIO1 / GPIO2 |
| UART5 TX / RX (9600 Bd) | 11 / 13 | GPS RX / TX, PPS on pin 15 |
| UART0 TX / RX (console) | 8 / 10 | CH340C (J21) and J3 |
| I²C SDA / SCL | 3 / 5 | J4, J12, all Qwiic sockets |
| EN / GPIO0 ESP32 A | 29 / 31 | via MOSFET, high = low on the ESP32 |
| EN / GPIO0 ESP32 B | 32 / 33 | via MOSFET, high = low on the ESP32 |

On the carrier board ESP32 A is on UART4 and ESP32 B on UART3 (the perfboard prototype uses the
opposite assignment). This keeps every connection on its own side of the board. The node software
identifies the two modems by their role (GET_INFO), so nothing has to be configured.

ESP32 ↔ LR2021 as in [assembly.md](../../docs/hardware/assembly.md), plus DIO7 → GPIO8 and
DIO8 → GPIO9. ESP32 A also controls the 868 MHz front end: GPIO42 = CSD, GPIO41 = CPS,
GPIO40 = CTX.

## Files

| File | Content |
|---|---|
| `generate_board.py` | generates the complete board (footprints, placement, nets, RF lines, routing, ground planes) |
| `astar.c` | path search used by the router (compiled automatically with gcc) |
| `make_outputs.py` | design rule check, Gerber/drill, BOM, placement, renders |
| `check_board.py` | checks every connection against the pin names of the modules, track lengths and part spacing |
| `lr2021-carrier.kicad_pcb` | the KiCad 9 board – can be opened and edited in KiCad |
| `netlist.json` | all connections |
| `fabrication/` | files for ordering and pictures |
| `../filter868/` | the plug-in 868 MHz filter module (own small board) |

Rebuild (Linux or WSL with KiCad 9, `python3-numpy`, `python3-scipy`, `gcc`):

```
python3 generate_board.py
python3 make_outputs.py
python3 check_board.py
```
