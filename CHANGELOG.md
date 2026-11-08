# Changelog

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
