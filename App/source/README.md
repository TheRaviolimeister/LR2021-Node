# LR2021 Node – App (source)

Flutter app for Android, Windows and Linux. User documentation: [docs/app.md](../../docs/app.md).

- `lib/core/` – modem protocol, transports (USB, network, node cable), updater
- `lib/mesh/` – Meshtastic (incl. PKI), MeshCore, LR radio protocol, file transfer
- `lib/geo/` – coordinates, map tiles, GPS, compass
- `lib/state/` – app state and settings
- `lib/ui/` – pages
- `lib/i18n.dart`, `lib/i18n_en.dart` – translations (German source texts, English dictionary)
- `tools/ci_prepare.sh` – creates and patches the platform folders (used by CI)

```
bash tools/ci_prepare.sh
flutter test
flutter build apk --release      # or: windows / linux
```
