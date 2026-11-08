# Node software (Orange Pi Zero 2W)

A ready-made SD card image based on Armbian (Debian 13 “trixie”). The service `lr2021d` connects the
two radio modems, the GPS, Wi-Fi, Bluetooth and USB and makes everything available on the network.

## First start

1. Insert the SD card and connect power. The first start takes 2–4 minutes.
2. The node gets a 4-character ID (e.g. `1A2B`): Wi-Fi `LR2021-1A2B`, hostname `lr2021-1a2b.local`.

## Connecting

| Way | Address | Note |
|---|---|---|
| Node Wi-Fi hotspot | `10.42.0.1` | network `LR2021-xxxx`, password `lr2021node` |
| Home Wi-Fi | via mDNS `lr2021-xxxx.local` | enter it in the web interface |
| USB-C to a PC (data cable) | `192.168.7.1` | network + serial console |
| Bluetooth | `LR2021-xxxx` | serial channels 1 = ESP32 A, 2 = ESP32 B, 3 = GPS |
| CP2102 (serial console) | COM port, 115200 | login console; the app uses it as “node cable” |

## Services and ports

| Port | Service |
|---|---|
| 22 | SSH |
| 80 | web interface (status, Wi-Fi, password, flash ESP32, update, reboot) |
| 2021 | ESP32 A (HF 868) – modem protocol |
| 2022 | ESP32 B (LF 433) – modem protocol |
| 2023 | GPS (NMEA) |

Over the serial console the app starts `/opt/lr2021/serialbridge.py`. After that both modems and the
GPS run over this one cable (frames `[channel][data]0x00`, channel 1 = A, 2 = B, 3 = GPS, 0x7F = control).

## Credentials (please change after the first start)

| What | Default |
|---|---|
| Login SSH/console | `lr2021` / `lr2021node` (root the same) |
| Web interface | password `lr2021node` |
| Wi-Fi hotspot | `lr2021node` |

## Updates

- Releases contain `LR2021-Node-update-<version>.tar.gz`.
- Install it in the web interface (Update) or via SSH:
  `sudo lr2021-update LR2021-Node-update-<version>.tar.gz`, revert with `sudo lr2021-update --rollback`.
- On Windows: `Node\Update_Node.bat` (finds the node and installs the newest package).

## Building the image yourself

Requirement: Windows with WSL2/Ubuntu (virtualisation enabled in the BIOS).

```
Node\1_Download.bat      download the Armbian base image
Node\Build_Image.bat     build the image (chroot + qemu), checks the result
Node\Write_SD.bat        write it to the SD card labelled “LR2021”
```

Sources of the image: `Node/source/` (services, configuration, device tree overlays, web interface),
build script `Node/build/build_image.sh`.

## Notes

- Own device tree overlays: `lr2021-uart34` (UART3/UART4 for the ESP32) and `lr2021-nothermal`
  (with this kernel the Zero 2W temperature sensor gives no valid readings and is disabled – provide
  cooling under continuous load).
- Wi-Fi hotspot WPA2-PSK only, without PMF (a limitation of the Wi-Fi driver).
- Log: `journalctl -u lr2021d -f`, configuration: `/etc/lr2021/node.json`.
