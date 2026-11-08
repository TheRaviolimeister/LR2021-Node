#!/usr/bin/env python3
"""After `flutter create`: set app name, Android permissions (network, USB, install) and window title."""
import pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent.parent
name = "LR2021 Node"

man = root / "android/app/src/main/AndroidManifest.xml"
if man.exists():
    s = man.read_text(encoding="utf-8")
    need = [
        '<uses-permission android:name="android.permission.INTERNET"/>',
        '<uses-feature android:name="android.hardware.usb.host" android:required="false"/>',
        '<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>',
        '<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>',
        '<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>',
    ]
    for line in need:
        if line not in s:
            s = s.replace("<application", line + "\n    <application", 1)
    s = re.sub(r'android:label="[^"]*"', 'android:label="%s"' % name, s, count=1)
    man.write_text(s, encoding="utf-8")
    print("Android-Manifest angepasst")

# Feste Signatur für Release-Builds: Schlüssel aus LR2021_KEYSTORE (CI) bzw. ~/.android/debug.keystore (lokal),
# damit Updates immer mit demselben Schlüssel signiert sind.
bg = root / "android/app/build.gradle.kts"
if bg.exists():
    s = bg.read_text(encoding="utf-8")
    if "lr2021Release" not in s:
        cfg = """    signingConfigs {
        create("lr2021Release") {
            storeFile = file(System.getenv("LR2021_KEYSTORE") ?: (System.getProperty("user.home") + "/.android/debug.keystore"))
            storePassword = System.getenv("LR2021_KEYSTORE_PASSWORD") ?: "android"
            keyAlias = System.getenv("LR2021_KEY_ALIAS") ?: "androiddebugkey"
            keyPassword = System.getenv("LR2021_KEY_PASSWORD") ?: "android"
        }
    }

    buildTypes {"""
        s = s.replace("    buildTypes {", cfg, 1)
        s = s.replace('signingConfig = signingConfigs.getByName("debug")', 'signingConfig = signingConfigs.getByName("lr2021Release")')
        bg.write_text(s, encoding="utf-8")
        print("Android-Signatur festgelegt")

gp = root / "android/gradle.properties"
if gp.exists():
    s = gp.read_text(encoding="utf-8")
    if "android.newDsl" not in s:
        s = s.rstrip() + "\nandroid.newDsl=false\n"
        gp.write_text(s, encoding="utf-8")
        print("android.newDsl=false gesetzt")

win = root / "windows/runner/main.cpp"
if win.exists():
    s = win.read_text(encoding="utf-8")
    s = s.replace('window.Create(L"lr2021_app"', 'window.Create(L"%s"' % name)
    s = s.replace("Win32Window::Size size(1280, 720);", "Win32Window::Size size(1280, 820);")
    win.write_text(s, encoding="utf-8")
    print("Windows-Fenstertitel gesetzt")

lin = root / "linux/runner/my_application.cc"
if not lin.exists():
    lin = root / "linux/my_application.cc"
if lin.exists():
    s = lin.read_text(encoding="utf-8")
    s = s.replace('"lr2021_app"', '"%s"' % name)
    lin.write_text(s, encoding="utf-8")
    print("Linux-Fenstertitel gesetzt")
ios = root / "ios/Runner/Info.plist"
if ios.exists():
    s = ios.read_text(encoding="utf-8")
    keys = {
        "CFBundleDisplayName": "LR2021 Node",
        "NSLocationWhenInUseUsageDescription": "Your position is shown on the map and can be shared on the mesh.",
        "NSMotionUsageDescription": "The compass turns the radar and the navigation arrow with the device.",
        "NSLocalNetworkUsageDescription": "The app connects to the LR2021 node in its Wi-Fi network.",
        "NSPhotoLibraryUsageDescription": "Choose a picture to send over LR radio.",
    }
    for k, v in keys.items():
        if "<key>%s</key>" % k in s:
            s = re.sub(r"(<key>%s</key>\s*<string>)[^<]*(</string>)" % k, r"\g<1>%s\g<2>" % v, s)
        else:
            s = s.replace("<dict>", "<dict>\n\t<key>%s</key>\n\t<string>%s</string>" % (k, v), 1)
    for k in ("UIFileSharingEnabled", "LSSupportsOpeningDocumentsInPlace"):
        if "<key>%s</key>" % k not in s:
            s = s.replace("<dict>", "<dict>\n\t<key>%s</key>\n\t<true/>" % k, 1)
    ios.write_text(s, encoding="utf-8")
    print("iOS-Info.plist angepasst")

# App-Symbol
import shutil
icons = root / "tools/icons"
for d in ["mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi"]:
    dst = root / f"android/app/src/main/res/mipmap-{d}/ic_launcher.png"
    if dst.parent.exists():
        shutil.copyfile(icons / f"ic_launcher_{d}.png", dst)
ico = root / "windows/runner/resources/app_icon.ico"
if ico.parent.exists():
    shutil.copyfile(icons / "app_icon.ico", ico)
print("App-Symbol gesetzt")
# iOS-App-Symbol: alle Größen aus icon_1024.png (sips gibt es auf macOS)
appicon = root / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
if appicon.exists() and shutil.which("sips"):
    import subprocess
    for png in appicon.glob("*.png"):
        out = subprocess.run(["sips", "-g", "pixelWidth", str(png)], capture_output=True, text=True).stdout
        w = int(out.strip().split()[-1])
        shutil.copyfile(icons / "icon_1024.png", png)
        subprocess.run(["sips", "-z", str(w), str(w), str(png)], capture_output=True)
    print("iOS-App-Symbol gesetzt")
sys.exit(0)
