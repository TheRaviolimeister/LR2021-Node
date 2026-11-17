# ESP32 firmware “LR2021-Modem”

The two ESP32-S3 are pure radio modems. They drive their LR2021 and carry out what the Orange Pi (or a
PC) tells them over the serial line: configure, transmit, receive. The protocol is described in
[modem-protocol.md](modem-protocol.md).

| File | Purpose |
|---|---|
| `LR2021-Modem-A.bin` (release) or `bin/lr2021_modem_A.bin` | **ESP32 A**, drives the Core2021-**HF** (868 MHz) |
| `LR2021-Modem-B.bin` (release) or `bin/lr2021_modem_B.bin` | **ESP32 B**, drives the Core2021-**LF** (433 MHz) |
| `firmware/lr2021_modem/` | source code (Arduino) |
| `firmware/build.sh` | builds both files with arduino-cli |
| `host/lrmodem.py` | control program and Python library (Pi and PC) |

The files are **not interchangeable**: the pin assignment to the LR2021 differs between A and B.

## Flashing

**Through the node (no cable on the ESP32, firmware ≥ 1.2.0 on the modem):** node web interface →
ESP32 A/B → upload firmware (`LR2021-Modem-A.bin` / `-B.bin`), or `Node\Update_ESP32.bat`. The node
sends the new firmware over the modem line (500000 baud, about 20–30 s per modem), the modem checks it
and restarts with it. The TCP/Bluetooth channel of that modem pauses during the update. A file for the
other modem, an older firmware than 1.2.0 or a damaged file is refused and the modem keeps running
with its current firmware. Stored settings and the front-end calibration are kept.

**From the Pi or a PC with `lrmodem.py`:** `lrmodem.py -p /dev/ttyS4 ota LR2021-Modem-A.bin`
(stop `lr2021d` first if it holds the port; `ota FILE --check` only checks the file).

**First time to 1.2.0:** firmware up to 1.1.0 has no update function, so the step to 1.2.0 has to be
made once over USB. The flash layout does not change, later updates work over the line. The easiest
way (node software ≥ 1.1.1, also for the perfboard build): connect the ESP32 with a USB cable from its
**“UART”/“COM”** socket to a USB port of the node and upload the file in the web interface as usual –
the node finds the same modem on USB and flashes it with esptool. Remove the cable afterwards. Or
flash it from a PC (below).

**Directly over USB:** connect the ESP32 to the PC at its **“COM”** socket. Writing the complete
image at 0x0 also erases the stored settings (they are set again by the app or with `lrmodem.py`).

- In the browser (Chrome/Edge): https://espressif.github.io/esptool-js/ → Connect → flash address
  **0x0**, choose the file → Program → then press RST.
- Or: `esptool.py --chip esp32s3 -p COM5 -b 921600 write_flash 0x0 lr2021_modem_A.bin`
- Or on Windows: `1_Flash_ESP32_A.bat` / `1_Flash_ESP32_B.bat` (needs Python 3 and esptool from the
  Arduino IDE).

If the connection fails: hold BOOT, press RST briefly, release BOOT.

### Flash layout and rollback

The image uses the standard 4 MB partition table of the ESP32 Arduino core (unchanged since the
first version, `firmware/build.sh` checks it after every build):

| Partition | Offset | Size | Use |
|---|---|---|---|
| nvs | 0x9000 | 20 KB | stored settings and calibration |
| otadata | 0xE000 | 8 KB | which application slot starts |
| app0 | 0x10000 | 1280 KB | application slot 0 (written by USB flashing) |
| app1 | 0x150000 | 1280 KB | application slot 1 |
| spiffs, coredump | 0x290000 | – | unused |

The application is about 450 KB, so each slot has about 65 % reserve. An update over the line always
goes into the slot that is not running. The new firmware starts “pending” and confirms itself with the
first valid frame from the Pi/PC; if that does not happen within 120 s, or it crashes before, the
bootloader starts the previous firmware again. Flashing the complete image over USB always makes
app0 the active slot.

## LED

| Colour | Meaning |
|---|---|
| short blue | start |
| dimmed blue | receiving |
| green flash | packet received |
| red (short) | transmitting |
| violet | firmware update in progress (radio paused) |
| permanently red | LR2021 does not respond |

## Interfaces

| Interface | Pins | Baud rate |
|---|---|---|
| to the Orange Pi | GPIO1 = RX, GPIO2 = TX | 500000 |
| USB “COM” | – | 115200 |

Both understand the same commands. 500000 baud because the Orange Pi (H618) UART can generate this
rate exactly.

## Default settings

| Modem | Frequency | Bandwidth | SF | CR | Sync | Preamble | Power |
|---|---|---|---|---|---|---|---|
| A | 869.525 MHz (Meshtastic EU_868 LongFast) | 250 kHz | 11 | 4/5 | 0x2B | 16 | 14 dBm |
| B | 433.875 MHz | 125 kHz | 9 | 4/5 | 0x12 | 8 | 10 dBm |

The app or the Pi switches the modems to the selected mode when connecting.

## Safety and limits

- **2.4 GHz is locked by default** until antennas are connected: `lrmodem.py -p … limits --ghz24 1`,
  then `save`.
- Maximum power: sub-GHz 22 dBm, 2.4 GHz 12 dBm (chip limits); tighter limits with `limits --max-subghz`.
- 868 MHz is an SRD band with a duty-cycle limit; the firmware can enforce it (`limits --duty`).
- 433 MHz / 70 cm: transmitting with full power only with an amateur radio licence; the LR radio
  protocol always transmits the callsign.

## 868 MHz front-end calibration

With the front end of the carrier board (ESP32 A), the firmware converts the requested power at the
antenna connector into the LR2021 level and corrects RSSI values with four values: PA gain, filter
loss, LNA gain and bypass loss (factory values 26 / 3 / 16 / 2 dB). If they are measured (power
meter or spectrum analyser at the antenna connector), they can be entered and are stored in flash:

```
lrmodem.py -p /dev/ttyS4 fe                                   # show state and calibration
lrmodem.py -p /dev/ttyS4 fe --pa-gain 24.5 --filter-loss 2.6  # set and store
lrmodem.py -p /dev/ttyS4 fe --filter-loss 0                   # without filter module (pins bridged)
lrmodem.py -p /dev/ttyS4 fe --defaults                        # back to the factory values
```

Ranges: PA 15–32 dB, filter 0–8 dB, LNA 5–22 dB, bypass 0–6 dB (0.1 dB steps). The legal limit of the
frequency is always applied, the LR2021 level never exceeds +8 dBm and is rounded down, so the
output never exceeds the requested power according to the calibration. Measure at the actual
frequency and voltage; a wrong value changes the real output power.

## Crystal offset

The Core2021 modules use a simple crystal without TCXO that is off by a few ppm (typically about
+30 kHz at 868 MHz on the Core2021-HF). The app measures the offset on received packets and corrects
it automatically (Settings → Radio and TX power → Frequency correction).

## Commands (`host/lrmodem.py`)

```
lrmodem.py -p PORT ping | info | config | stats
lrmodem.py -p PORT lora [--preset NAME] [--freq MHz --bw kHz --sf 5..12 --cr 5..8 --sync 0x12 --power dBm --preamble N]
lrmodem.py -p PORT fsk --freq MHz [--bitrate --fdev --rxbw --power --sync HEX]
lrmodem.py -p PORT limits [--subghz 0/1 --ghz24 0/1 --max-subghz dBm --max-24 dBm --duty permille]
lrmodem.py -p PORT tx "Text" | --hex 0102 [--lbt] [--repeat N --interval s]
lrmodem.py -p PORT rx | monitor | rssi | cad | standby | sleep
lrmodem.py -p PORT autorx 0/1 | save | factory | reset-radio | reboot
lrmodem.py -p PORT fe [--lna auto|an|aus] [--pa-gain dB --filter-loss dB --lna-gain dB --bypass-loss dB] [--defaults] [--no-save]
lrmodem.py -p PORT ota FILE [--check]
```
Presets: `meshtastic-eu`, `meshtastic-eu-mf`, `meshcore-eu`, `test-868`, `test-433`.

## Building it yourself

- arduino-cli or Arduino IDE 2 with **esp32 by Espressif 3.1.3**
- **RadioLib** from GitHub (commit `9b98f8e`); release 7.8.1 does not yet contain all LR2021 functions
- Board: ESP32S3 Dev Module, flash 4 MB, flash mode DIO, PSRAM disabled, USB CDC On Boot disabled
- Role via `-DMODEM_ROLE_A` / `-DMODEM_ROLE_B`; `firmware/build.sh` builds both into `firmware/bin/`
  and checks partition table, slot reserve, image layout and the identifier of each role
- Partition scheme: Default 4MB with spiffs (do not change, updates over the line rely on it)

## Troubleshooting

| Symptom | Cause |
|---|---|
| ESP32 does not start, console shows `waiting for download` | GPIO0 is LOW at boot (check for solder bridges) |
| `info`: `radio_ok False`, `init_code -705` | BUSY stays HIGH: check BUSY, RESET or 3.3 V to the module |
| `info`: `radio_ok False`, `init_code -2` | LR2021 does not answer: SPI lines, BUSY/RESET, 3.3 V |
| no answer on the Pi | wrong firmware (A/B), TX/RX swapped, baud rate |
| no answer on USB | use the “COM” socket instead of “USB”, 115200 baud |
| `tx` reports a timeout | IRQ line (DIO11) missing or broken |
| `link_bad_frames` increases | interference on the UART line, check solder joints |
| update: “firmware for the other modem” | file A/B swapped – use the file of the modem's role |
| update: “older than 1.2.0” | the modem still runs ≤ 1.1.0: flash 1.2.0 once over USB |
| after an update the old version is back | the new firmware got no frame within 120 s (rollback); check the line and try again |
