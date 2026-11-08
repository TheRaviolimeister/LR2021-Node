#!/usr/bin/env bash
# Create and patch the platform folders (CI and Linux builds). Run in the app folder: tools/ci_prepare.sh
set -euo pipefail
cd "$(dirname "$0")/.."
flutter create --platforms=android,windows,linux --project-name lr2021_app --org de.lr2021 . >/dev/null
python3 tools/patch_platforms.py
flutter pub get
# Adapt Android plugins to current Gradle: all to compileSdk 36, older ones also jcenter/namespace
CACHE="${PUB_CACHE:-$HOME/.pub-cache}/hosted/pub.dev"
for g in "$CACHE"/*/android/build.gradle; do
  [ -f "$g" ] || continue
  sed -i -E 's/jcenter\(\)/mavenCentral()/; s/compileSdkVersion +[0-9]+/compileSdkVersion 36/; s/compileSdk *=? *[0-9]+/compileSdk 36/' "$g"
  case "$g" in
    *usb_serial-*) ns=dev.bessems.usbserial ;;
    *flutter_libserialport-*) ns=org.sigrok.flutter_libserialport ;;
    *) continue ;;
  esac
  grep -q namespace "$g" || sed -i "0,/android *{/s//android {\n    namespace '$ns'/" "$g"
done
gp=android/gradle.properties
for kv in android.newDsl=false android.builtInKotlin=false; do
  grep -q "^${kv%%=*}" "$gp" || echo "$kv" >> "$gp"
done
echo "Platforms prepared"
