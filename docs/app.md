# App “LR2021 Node”

An app for **Android, iOS, Windows and Linux** (Flutter). Language English or German
(Settings → Appearance and data).

## Installing

From the latest [release](https://github.com/TheRaviolimeister/LR2021-Node/releases/latest):

| System | File | Installation |
|---|---|---|
| Android | `LR2021-Node-android.apk` | open it, allow installing from this source |
| Windows | `LR2021-Node-windows-x64.zip` | unzip, start `lr2021_app.exe` |
| Linux (x64) | `LR2021-Node-linux-x64.tar.gz` | unpack, start `lr2021_app` |
| iPhone / iPad | `LR2021-Node-ios.ipa` | with AltStore / SideStore / Sideloadly, see below |

**Updates:** the app checks for a new version on start and offers it (Settings → App update). Android
opens the installer; Windows and Linux replace the program files and restart.

### iPhone / iPad

Apple only allows apps from the App Store, so the iOS app is installed with a sideloading tool and your
own Apple ID:

1. Install **AltStore** (https://altstore.io) or **SideStore** (https://sidestore.io) on the iPhone.
2. In AltStore/SideStore → Sources → **+**, add the source
   `https://raw.githubusercontent.com/TheRaviolimeister/LR2021-Node/dist/altstore-source.json`
3. Install “LR2021 Node” from that source. New versions then appear there and are installed automatically.

Alternatively install `LR2021-Node-ios.ipa` from the release with Sideloadly. With a free Apple ID the
app has to be re-signed every 7 days (AltStore/SideStore does this in the background). On iOS the app
connects to the node over Wi-Fi (“Network (Pi)”); USB connections are not available.

## Connecting (Radio → ESP32 A / B → Connection)

| Type | When |
|---|---|
| **Network (Pi)** | phone/PC in the node's Wi-Fi: address `10.42.0.1` (USB network: `192.168.7.1`) |
| **Node cable** | PC via USB on the node's CP2102; the app logs in to the console and connects A, B and GPS over the one cable |
| **ESP32 USB** | a single modem directly over USB (“COM” socket) |
| **Bluetooth (node)** | Android: pair the node once (“LR2021-xxxx”, no PIN), then everything – both modems, GPS, mailbox – runs over one Bluetooth connection; the phone's Wi-Fi and mobile data stay free |
| **Demo** | simulated modem for trying things out |

## Features

- **Chat:** Meshtastic channels (default key and own keys), end-to-end encrypted direct messages
  (Meshtastic PKI), delivery confirmation, quick messages, SOS with position (MGRS). The paperclip
  sends your position from the node's GPS into any chat (MGRS and degrees; on Meshtastic also as a
  position packet).
- **LR radio 70 cm:** own plain-text channel with callsign (default 433.650 MHz, 125 kHz, SF9 – away from
  the licence-free devices on 433.92 MHz and from LoRa APRS), automatic acknowledgement, **photos (camera
  or gallery), voice messages and files** up to 1 MB. Pictures in three sizes (480 / 800 / 1280 px) or
  the original, the dialog shows the airtime; voice messages AAC, up to 2 minutes (about 3 KB/s);
  missing parts are requested selectively. A file is announced three times before it is sent and goes
  out with the highest permitted power; other nodes hold back their own transmissions meanwhile. The
  sender resends missing parts until every receiver reports the file complete, and before every part
  it waits while someone else is transmitting loudly on the frequency (also non-LoRa signals).
  Optionally files go over a **2.4 GHz file channel**
  (2425 MHz, SF5, 812 kHz, about ten times faster, shorter range): the sender announces the file on
  70 cm, both sides switch to 2.4 GHz for the transfer and come back afterwards; if nobody answers
  there, the file is sent on 70 cm. Needs 2.4 GHz antennas and the setting on both sides.
- **Node mailbox:** connected through the node (Bluetooth, network or node cable), the app hands pictures
  and files to the node, which sends them on even after the phone disconnects. The node keeps receiving
  without the phone; on the next connection the app fetches everything it missed. **Radio → LR radio →
  “Find the quietest frequency”** lets the node measure for 1–60 minutes how busy each channel is (70 cm
  amateur band or the licence-free range); one of the quietest – or an own frequency – becomes the LR
  radio frequency.
- **Nodes:** every station heard (Meshtastic, MeshCore, LR radio) with signal, hops, device, battery,
  position, distance; request node info, position and telemetry, trace route, favourites, ignore.
- **Map:** topo, satellite, hybrid (aerial imagery with street names), street; save areas for offline
  use, waypoints, measuring, MGRS/locator; the map can rotate with the device.
- **Radar and navigation:** situation display without internet that rotates with the compass;
  “Navigate” to a node or waypoint – an arrow shows direction and distance.
- **Radio:** mode per modem (Meshtastic, MeshCore listen-only, LR radio, manual), LoRa settings, power,
  noise level, statistics.
- **Monitor:** every packet raw and decrypted, reception log as CSV for range tests.
- **Transmit power:** legal maximum per frequency automatically, amateur radio mode with callsign.

## Building it yourself

Windows: `App\1_Setup.bat` (downloads Flutter, JDK and the Android SDK to `%USERPROFILE%\LR2021-Tools`),
then `App\2_Build.bat`. Result in `App\output\`.

Linux: install Flutter, then in the folder `App/source`:
```
bash tools/ci_prepare.sh
flutter build linux --release
```

GitHub Actions builds releases automatically (`.github/workflows/release.yml`) as soon as a tag
`vX.Y.Z` is pushed.

## Translations

The source code contains the German texts inside `tr('…')`; the English texts are in
`lib/i18n_en.dart`. Always write new texts with `tr()` and add the translation there.
