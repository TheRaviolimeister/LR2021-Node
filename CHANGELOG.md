# Changelog

## 1.7.1

- Node 1.1.1: an ESP32 with firmware older than 1.2.0 (for example on a perfboard build) can be brought
  to 1.2.0 through the node – connect it with a USB cable to a USB port of the node and upload the
  firmware in the web interface; the node finds the same modem on USB and flashes it. All later
  updates go over the modem line
- App: plain-text messages for the firmware-update status codes
- Documentation: perfboard builds stay supported by all firmware, node and app versions

## 1.7.0

- Carrier board 1.3: 868 MHz front end (Skyworks SE2435L, up to 1 W, LNA with bypass), a socket for a
  plug-in 868 MHz filter module (`hardware/filter868`), ESD shunt inductors at all four antenna
  connectors (< 0.05 dB), control lines to the front end as straight lanes
- ESP32 firmware 1.2.0 (the step from 1.1.0 or older to 1.2.0 must be flashed once over USB):
  - detects the 868 MHz front end, converts the transmit power to the drive level of the LR2021 and
    enforces the legal limits of the frequency (27 dBm in 869.4–869.65 MHz, otherwise 14 dBm), whatever
    is requested; switches the LNA automatically by the measured noise floor (or fixed on/off); RSSI
    refers to the antenna connector; new commands FE_GET / FE_SET
  - measured PA gain, filter loss, LNA gain and bypass loss can be stored (`lrmodem.py fe --pa-gain …`)
  - both modems can be updated over the modem link (node web interface or `lrmodem.py ota`); every
    update is checked (SHA-256, image check, correct modem A/B, version) before switching, and the
    modem goes back to the previous firmware if the new one does not come up. The radio pauses during
    an update (front end asleep, violet LED); stored settings are kept
- Node 1.1.0: ESP32 updates over the modem link (esptool only for an ESP32 on USB); I2C bus on header
  pins 3/5 for the carrier board's Qwiic/I2C sockets – always `/dev/i2c-1`, 100 kHz (overlay
  `lr2021-i2c1`, installed by the node update, reboot required); the node image includes i2c-tools
- App: recognises the front end and then allows the full 27 dBm in 869.4–869.65 MHz; Radio → Modem
  shows the front end (PA/bypass, power, noise floor) and switches the LNA (automatic / on / off)

## 1.6.6

- Maintenance release (no functional changes)

## 1.6.5

- Android: app update is downloaded to the app's own storage instead of the cache folder (the system
  could remove the file during the download)
- If an update download fails on Android, the download is opened in the browser instead

## 1.6.4

- Settings → App update shows where the update information came from (GitHub or mirror)

## 1.6.3

- Updates keep working when the GitHub API or the release downloads are disturbed: every release is
  also published in the branch `dist` (reachable via raw.githubusercontent.com and jsDelivr); the app
  falls back to it automatically and verifies every download with SHA-256
- The AltStore/SideStore source moved to
  `https://raw.githubusercontent.com/TheRaviolimeister/LR2021-Node/dist/altstore-source.json`

## 1.6.2

- Radio: the receiver front-end calibration is now forced every time a modem is configured. Before, the
  LR2021 could receive without calibration (chip error 0x0200), which costs sensitivity and SNR.
  Firmware 1.0.16 does the same on its own; with app 1.6.2 the fix also works with firmware 1.0.15.
- Frequency correction is measured on every received packet (including relays of your own messages), so
  the crystal offset of the radio module is corrected automatically after a few packets.
- Data from the demo modem is no longer stored; demo nodes and messages from earlier versions are removed.
- ESP32 firmware 1.0.16

## 1.6.1

- iOS app (iPhone/iPad), installable with AltStore, SideStore or Sideloadly; the release contains an
  AltStore/SideStore source, so the app is updated automatically from there
- On iOS the app connects to the node over Wi-Fi (USB is not available on iOS)

## 1.6.0

First public release.

- App for Android, Windows and Linux, English and German, with automatic updates from the GitHub releases
- Meshtastic: channels, end-to-end encrypted direct messages (PKI), node info, position and telemetry requests, traceroute, waypoints
- LR radio (70 cm, amateur radio): text, beacon, images and files with selective retransmission
- Map (topo, satellite, hybrid, street; offline areas), radar and compass navigation to nodes and waypoints
- Connection to the node via Wi-Fi, USB network, Bluetooth or the serial console cable
- ESP32 modem firmware 1.0.15, node software with web interface, update packages
- Automatic crystal frequency correction from received packets
