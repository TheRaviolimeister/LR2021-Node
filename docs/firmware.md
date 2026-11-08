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

**Through the node (no cable on the ESP32):** node web interface → ESP32 A/B → upload firmware, or
`Node\Update_ESP32.bat`.

**Directly over USB:** connect the ESP32 to the PC at its **“COM”** socket.

- In the browser (Chrome/Edge): https://espressif.github.io/esptool-js/ → Connect → flash address
  **0x0**, choose the file → Program → then press RST.
- Or: `esptool.py --chip esp32s3 -p COM5 -b 921600 write_flash 0x0 lr2021_modem_A.bin`
- Or on Windows: `1_Flash_ESP32_A.bat` / `1_Flash_ESP32_B.bat` (needs Python 3 and esptool from the
  Arduino IDE).

If the connection fails: hold BOOT, press RST briefly, release BOOT.

## LED

| Colour | Meaning |
|---|---|
| short blue | start |
| dimmed blue | receiving |
| green flash | packet received |
| red (short) | transmitting |
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
```
Presets: `meshtastic-eu`, `meshtastic-eu-mf`, `meshcore-eu`, `test-868`, `test-433`.

## Building it yourself

- arduino-cli or Arduino IDE 2 with **esp32 by Espressif 3.1.3**
- **RadioLib** from GitHub (commit `9b98f8e`); release 7.8.1 does not yet contain all LR2021 functions
- Board: ESP32S3 Dev Module, flash 4 MB, flash mode DIO, PSRAM disabled, USB CDC On Boot disabled
- Role via `-DMODEM_ROLE_A` / `-DMODEM_ROLE_B`; `firmware/build.sh` builds both into `firmware/bin/`

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
