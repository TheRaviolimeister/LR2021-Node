# App “LR2021 Node”

An app for **Android, iOS, Windows and Linux** (Flutter). Language English or German
(Settings → Appearance and data).

## Installing

From the latest [release](../../releases/latest):

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
   `https://github.com/TheRaviolimeister/LR2021-Node/releases/latest/download/altstore-source.json`
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
| **Demo** | simulated modem for trying things out |

## Features

- **Chat:** Meshtastic channels (default key and own keys), end-to-end encrypted direct messages
  (Meshtastic PKI), delivery confirmation, quick messages, SOS with position (MGRS).
- **LR radio 70 cm:** own plain-text channel with callsign, automatic acknowledgement, **images and
  files** (images are reduced to 480 px; missing parts are requested selectively).
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
