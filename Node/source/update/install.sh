#!/bin/sh
# LR2021 Node – Systemkorrekturen für Nodes mit älterem Image (wird vom Update automatisch als root ausgeführt).
# Mehrfach ausführbar (idempotent). Dateien liegen neben diesem Script im entpackten Paket.
# Achtung: Läuft, BEVOR die Antwort ans Update-Programm geht – hier nichts tun, was eine bestehende
# WLAN-Verbindung trennt. Den Wechsel auf den neuen Hotspot macht lr2021d beim Neustart danach.
# Test: LR2021_ROOT=/tmp/x sh install.sh  (schreibt nur unter /tmp/x, ruft keine Systembefehle auf)
D=$(cd "$(dirname "$0")" && pwd)
R=${LR2021_ROOT:-}
run() { [ -z "$R" ] && "$@" 2>/dev/null; return 0; }
echo "LR2021 Systemkorrekturen aus $D"

inst() {  # inst MODUS DATEI (relativ im Paket = Zielpfad ohne führendes /)
  if [ -f "$D/$2" ]; then
    install -d "$(dirname "$R/$2")"
    if install -m "$1" "$D/$2" "$R/$2"; then echo "  installiert: /$2"; else echo "  FEHLER: /$2"; fi
  fi
}

# 1) Neuer Hotspot-Dienst (wpa_supplicant-AP nur WPA-PSK + dnsmasq) statt NetworkManager-Hotspot
inst 755 usr/local/sbin/lr2021-hotspot
inst 644 etc/systemd/system/lr2021-hotspot.service
inst 644 etc/udev/rules.d/91-lr2021-wlan.rules
run systemctl daemon-reload
run systemctl enable lr2021-hotspot.service
echo "  lr2021-hotspot aktiviert (startet mit dem Neustart von lr2021d)"

# 2) Heim-WLAN-Profile: PMF aus (UWE5622-Treiber kann kein PMF)
for f in "$R"/etc/NetworkManager/system-connections/LR2021-WLAN*.nmconnection; do
  [ -f "$f" ] || continue
  grep -q '^\[wifi-security\]' "$f" || continue
  if grep -q '^pmf=' "$f"; then sed -i 's/^pmf=.*/pmf=1/' "$f"; else sed -i '/^\[wifi-security\]/a pmf=1' "$f"; fi
  chmod 600 "$f"; echo "  Heim-WLAN: pmf=1"
done
run nmcli connection reload

# 3) USB-Netz: usb0 nicht mehr "unmanaged" (nur usb0 triggern – wlan0 nicht anfassen, siehe oben)
inst 644 etc/udev/rules.d/90-lr2021-usb-gadget.rules
run udevadm control --reload
[ -e /sys/class/net/usb0 ] && run udevadm trigger --action=change /sys/class/net/usb0

# 4) Serielle Logins: feste Terminalgröße, kein root-Autologin
inst 644 "etc/systemd/system/serial-getty@.service.d/lr2021.conf"
rm -f "$R/etc/systemd/system/serial-getty@.service.d/override.conf" "$R/etc/systemd/system/getty@.service.d/override.conf"
run systemctl daemon-reload
echo "  root-Autologin entfernt"

# 5) Eigene Device-Tree-Overlays (wirken nach Neustart):
#    lr2021-nothermal = falsche Temperaturwerte -> Sensor aus
#    lr2021-uart34    = UART3/UART4 für ESP32 A/B (Kernel-DT hat falsches Pinmux)
ENV=$R/boot/armbianEnv.txt
for o in lr2021-nothermal lr2021-uart34; do
  [ -f "$D/$o.dtbo" ] && [ -f "$ENV" ] || continue
  install -d "$R/boot/overlay-user"
  install -m 644 "$D/$o.dtbo" "$R/boot/overlay-user/"
  if grep -q '^user_overlays=' "$ENV"; then
    grep -qE "^user_overlays=.*\b$o\b" "$ENV" || sed -i -E "s/^user_overlays=(.*)\$/user_overlays=\1 $o/" "$ENV"
  else
    echo "user_overlays=$o" >> "$ENV"
  fi
  echo "  Overlay $o eingetragen (wirkt nach Neustart)"
done

# 6) Baudrate zu den ESP32: 500000 (der H618-UART kann 460800 nicht exakt erzeugen); ältere Konfigurationen umstellen
NJ=$R/etc/lr2021/node.json
if [ -f "$NJ" ] && grep -q '"uart_baud": *460800' "$NJ"; then
  sed -i 's/"uart_baud": *460800/"uart_baud": 500000/' "$NJ"
  echo "  node.json: uart_baud 460800 -> 500000"
fi

# 7) Versionsdatei
if [ -f "$D/lr2021/lr2021d.py" ]; then
  V=$(sed -n 's/^VERSION = "\(.*\)"/\1/p' "$D/lr2021/lr2021d.py")
  [ -n "$V" ] && echo "node-$V $(date +%Y-%m-%d)" > "$R/etc/lr2021/version" 2>/dev/null && echo "  Version node-$V"
fi
sync
echo "Systemkorrekturen fertig. lr2021d startet gleich neu und schaltet auf den neuen Hotspot um"
echo "(WLAN-Verbindung bricht dabei kurz ab). Für das Overlay einmal neu starten."
