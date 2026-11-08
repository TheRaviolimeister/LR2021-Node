LR2021 Node – quick guide
=========================

FIRST START
  - Put the SD card into the Orange Pi Zero 2W, connect power/cable to the USB-C socket.
  - The first start takes 2–4 minutes (the partition is grown to the whole card,
    SSH keys and the node ID are generated).
  - The node gets a 4-character ID (e.g. 1A2B). From it:
      Wi-Fi name  LR2021-1A2B
      Hostname    lr2021-1a2b  →  http://lr2021-1a2b.local

CONNECTING
  Wi-Fi (the node's hotspot)
    Network "LR2021-xxxx", password lr2021node
    Browser: http://10.42.0.1      App: Network (Pi) → 10.42.0.1
    (If a home Wi-Fi is entered in the web interface and reachable,
     the node connects to it instead.)

  USB-C to a PC/phone
    A new network appears (Windows 10/11 without drivers).
    Browser: http://192.168.7.1     SSH: ssh lr2021@192.168.7.1
    Plus a COM port with a login console (115200 baud, e.g. PuTTY).

  Bluetooth
    Pair "LR2021-xxxx" (no PIN). Serial channels: 1 = ESP32 A,
    2 = ESP32 B, 3 = GPS.

PORTS
  22 SSH · 80 web · 2021 ESP32 A (HF 868) · 2022 ESP32 B (LF 433) · 2023 GPS (NMEA)

ACCESS (defaults – please change after the first start!)
  Login (SSH/console):  user lr2021, password lr2021node  (root the same)
                        change: via SSH "passwd" and "sudo passwd root"
  Web admin password:   lr2021node  (web interface → admin password)
  Wi-Fi hotspot:        lr2021node  (web interface → Wi-Fi hotspot)
  When changing settings the browser asks for a user (any) and the password.

UPDATE (node connected via USB-C or Wi-Fi)
  Build_Update_Package.bat   packs source\opt\lr2021 into packages\lr2021-update-….tar.gz
  Update_Node.bat            installs the newest package (the old version is kept as backup)
  Update_ESP32.bat           flashes lr2021_modem_A.bin / _B.bin through the node
  Without the web interface (SSH over USB):
    scp packages\lr2021-update-….tar.gz lr2021@192.168.7.1:
    ssh lr2021@192.168.7.1 sudo lr2021-update lr2021-update-….tar.gz
    ssh lr2021@192.168.7.1 sudo lr2021-update --rollback     (back to the previous version)

WRITING THE SD CARD
  Build_Image.bat     builds the image (WSL2/Ubuntu, virtualisation enabled in the BIOS)
  Write_SD.bat        writes image\LR2021-Node-*.img to the card labelled "LR2021"
                      (asks for admin rights and for "ja" before writing).
  A card that was already flashed has no label any more: format it in Windows as FAT32
  with the label LR2021 – or: write_sd.ps1 -OhneLabel -DiskNummer N
  If Windows then asks "Format disk?" → click CANCEL.

ESP32 FIRMWARE
  The node talks to the ESP32 over UART3/UART4 at 500000 baud (firmware "LR2021-Modem",
  files LR2021-Modem-A.bin / -B.bin from the release). Check: web interface → ESP32 A/B → firmware.

KNOWN LIMITATIONS
  - The temperature sensor is disabled (overlay lr2021-nothermal): with Armbian kernel
    6.18.60 the Zero 2W reports wrong values (150–260 °C), which would shut the node down
    right after booting. Result: no temperature display, no thermal throttling –
    provide cooling under continuous load.
  - USB network/USB COM need a USB-C DATA cable directly to the PC (charge-only cables
    or a power supply: power only).
  - Wi-Fi hotspot WPA2-PSK only, without PMF (802.11w) – the Wi-Fi driver does not support it.
    The hotspot therefore runs as its own service (lr2021-hotspot: wpa_supplicant + dnsmasq),
    not through NetworkManager. Status: systemctl status lr2021-hotspot

TROUBLESHOOTING
  Status:   http://<address>/  or via SSH: systemctl status lr2021d
  Log:      journalctl -u lr2021d -f        first start: /var/log/lr2021-firstboot.log
  Config:   /etc/lr2021/node.json  (then: sudo systemctl restart lr2021d)
  Serial console: CP2102 on pins 8/10 (ttyS0, 115200)
