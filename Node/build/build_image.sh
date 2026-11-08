#!/bin/bash
# LR2021 Node – Image bauen (in WSL2/Ubuntu als root):
#   wsl -d Ubuntu -u root -- bash /mnt/c/Users/<du>/Documents/LR2021-Modem/Node/build/build_image.sh
# Ergebnis: Node/image/LR2021-Node-<datum>.img (+ .img.xz + .sha256)
set -Eeuo pipefail
trap 'echo "FEHLER in Zeile $LINENO: $BASH_COMMAND" >&2' ERR

NODE=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
SRC=$NODE/source
B=/root/lr2021-build
MNT=/mnt/lr
DATE=$(date +%Y%m%d)
OUTNAME=LR2021-Node-$DATE
SIZE=3584M                      # 3,5 GB
LOOP=""

say() { echo; echo "=== $*"; }
[ "$(id -u)" = 0 ] || { echo "Bitte als root starten (wsl -u root)"; exit 1; }
mkdir -p "$B"

cleanup() {
  set +e
  for m in "$MNT/dev/pts" "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/run" "$MNT"; do
    mountpoint -q "$m" && umount -l "$m"
  done
  [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
  return 0
}
trap cleanup EXIT

# ------------------------------------------------------------------ 1. Werkzeuge
say "Werkzeuge in WSL installieren"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq xz-utils binfmt-support parted e2fsprogs rsync curl \
  device-tree-compiler file nftables python3 >/dev/null
apt-get install -y -qq qemu-user-static >/dev/null 2>&1 || apt-get install -y -qq qemu-user qemu-user-binfmt >/dev/null
QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64)
file -L "$QEMU" | grep -qE "statically linked|static-pie linked" || { echo "qemu-aarch64 ist nicht statisch gelinkt: $QEMU"; exit 1; }
mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
  update-binfmts --enable qemu-aarch64 2>/dev/null || systemctl restart systemd-binfmt 2>/dev/null || true
fi
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || { echo "binfmt für aarch64 fehlt"; exit 1; }
echo "qemu: $QEMU"

# ------------------------------------------------------------------ 2. Basis-Image prüfen
say "Basis-Image prüfen"
XZ=$(ls -1 "$NODE"/download/Armbian_*Orangepizero2w_trixie_current_*minimal.img.xz | tail -n1)
SHA=$(cut -d' ' -f1 "$XZ.sha")
echo "$(basename "$XZ")"
echo "$SHA  $XZ" | sha256sum -c -
xz -t "$XZ" && echo "xz -t: OK"

# ------------------------------------------------------------------ 3. Entpacken, vergrößern
say "Entpacken und auf $SIZE vergrößern"
IMG=$B/$OUTNAME.img
xz -dc -T0 "$XZ" > "$IMG"
truncate -s "$SIZE" "$IMG"
parted -s "$IMG" print
parted -s "$IMG" resizepart 1 100%
LOOP=$(losetup -fP --show "$IMG")
sleep 1
PART=${LOOP}p1
[ -b "$PART" ] || { partx -a "$LOOP" || true; sleep 1; }
e2fsck -fy "$PART" || [ $? -le 1 ]
resize2fs "$PART"

# ------------------------------------------------------------------ 4. Mounten, chroot vorbereiten
say "Mounten und chroot vorbereiten"
mkdir -p "$MNT"
mount "$PART" "$MNT"
for d in dev dev/pts proc sys run; do mkdir -p "$MNT/$d"; done
mount --bind /dev "$MNT/dev"; mount --bind /dev/pts "$MNT/dev/pts"
mount -t proc proc "$MNT/proc"; mount -t sysfs sysfs "$MNT/sys"; mount -t tmpfs tmpfs "$MNT/run"
# resolv.conf (Original – evtl. Symlink – sichern)
if [ -e "$MNT/etc/resolv.conf" ] || [ -L "$MNT/etc/resolv.conf" ]; then mv "$MNT/etc/resolv.conf" "$MNT/etc/resolv.conf.lr2021-orig"; fi
cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"
cp "$QEMU" "$MNT/usr/bin/qemu-aarch64-static"
printf '#!/bin/sh\nexit 101\n' > "$MNT/usr/sbin/policy-rc.d"; chmod 755 "$MNT/usr/sbin/policy-rc.d"
in_chroot() { LANG=C.UTF-8 LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive chroot "$MNT" /bin/bash -c "$1"; }
in_chroot "uname -m; cat /etc/os-release | head -3"

# ------------------------------------------------------------------ 5. Pakete
say "Pakete installieren (dauert unter qemu einige Minuten)"
in_chroot "apt-get update"
in_chroot "apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
  network-manager dnsmasq-base avahi-daemon libnss-mdns nftables bluez bluez-tools rfkill iw \
  python3 python3-serial esptool gpsd-clients pps-tools openssh-server ca-certificates usbutils sudo"
in_chroot "apt-get clean"
in_chroot "command -v sdptool bluetoothctl nmcli esptool nft python3" || true

# ------------------------------------------------------------------ 6. Dateien aus source/
say "LR2021-Dateien kopieren"
rm -rf "$MNT/opt/lr2021"
mkdir -p "$MNT/opt"
cp -r "$SRC/opt/lr2021" "$MNT/opt/lr2021"
find "$MNT/opt/lr2021" -name __pycache__ -prune -exec rm -rf {} +
# netplan: Armbian-Dateien (systemd-networkd) raus, NetworkManager rein
mkdir -p "$MNT/root/netplan-armbian"
find "$MNT/etc/netplan" -maxdepth 1 -name '*.yaml' ! -name '10-lr2021.yaml' -exec mv {} "$MNT/root/netplan-armbian/" \; 2>/dev/null || true
cp -r --remove-destination "$SRC/rootfs/." "$MNT/"     # ersetzt auch Symlinks (z. B. Armbians /etc/motd)
# Zeilenenden (Windows) entfernen, Besitzer/Rechte
( cd "$SRC/rootfs" && find . -type f ) | while read -r f; do sed -i 's/\r$//' "$MNT/${f#./}"; chown root:root "$MNT/${f#./}"; chmod 644 "$MNT/${f#./}"; done
find "$MNT/opt/lr2021" -type f \( -name '*.py' -o -name '*.html' \) -exec sed -i 's/\r$//' {} +
chown -R root:root "$MNT/opt/lr2021"; chmod -R u=rwX,go=rX "$MNT/opt/lr2021"
chmod 755 "$MNT/opt/lr2021/lr2021d.py" "$MNT/opt/lr2021/lrmodem.py" "$MNT/opt/lr2021/serialbridge.py"
chmod 755 "$MNT"/usr/local/sbin/lr2021-*
chmod 600 "$MNT"/etc/NetworkManager/system-connections/*.nmconnection
chmod 600 "$MNT"/etc/netplan/*.yaml
chmod 755 "$MNT/etc/nftables.conf"
chmod 600 "$MNT/etc/lr2021/node.json"      # enthält das Admin-Passwort
# Hotspot läuft über lr2021-hotspot.service, nicht NetworkManager (altes Profil sicher entfernen)
rm -f "$MNT/etc/NetworkManager/system-connections/LR2021-Hotspot.nmconnection"
mkdir -p "$MNT/var/lib/lr2021"
NODEVER=$(sed -n 's/^VERSION = "\(.*\)"/\1/p' "$SRC/opt/lr2021/lr2021d.py")
echo "node-$NODEVER $(date +%Y-%m-%d)" > "$MNT/etc/lr2021/version"

# ------------------------------------------------------------------ Bluetooth
say "Bluetooth konfigurieren"
BTD=$(sed -n 's/^ExecStart=\([^ ]*bluetoothd\).*/\1/p' "$MNT/lib/systemd/system/bluetooth.service" | head -n1)
[ -n "$BTD" ] || BTD=/usr/libexec/bluetooth/bluetoothd
mkdir -p "$MNT/etc/systemd/system/bluetooth.service.d"
printf '# LR2021: bluetoothd im Kompatibilitätsmodus, damit sdptool die seriellen Kanäle (SPP 1/2/3) eintragen kann\n[Service]\nExecStart=\nExecStart=%s --compat\n' "$BTD" \
  > "$MNT/etc/systemd/system/bluetooth.service.d/lr2021.conf"
cp "$MNT/etc/systemd/system/bluetooth.service.d/lr2021.conf" "$SRC/rootfs/etc/systemd/system/bluetooth.service.d/lr2021.conf"
MC=$MNT/etc/bluetooth/main.conf
[ -f "$MC" ] || printf '[General]\n' > "$MC"
setbt() {   # Schlüssel in [General] setzen (auskommentierte Vorlage ersetzen oder anhängen)
  if grep -qE "^[#[:space:]]*$1[[:space:]]*=" "$MC"; then
    sed -i -E "0,/^[#[:space:]]*$1[[:space:]]*=.*/s//$1 = $2/" "$MC"
  else
    sed -i "/^\[General\]/a $1 = $2" "$MC"
  fi
}
setbt Name LR2021-Node
setbt DiscoverableTimeout 0
setbt PairableTimeout 0
setbt AlwaysPairable true
setbt JustWorksRepairing always
grep -E '^(Name|DiscoverableTimeout|PairableTimeout|AlwaysPairable|JustWorksRepairing) =' "$MC"
mkdir -p "$SRC/referenz"; cp "$MC" "$SRC/referenz/bluetooth-main.conf"

# ------------------------------------------------------------------ armbianEnv: UART5 + OTG
say "armbianEnv.txt / Device-Tree"
ENV=$MNT/boot/armbianEnv.txt
cat "$ENV"
PFX=$(sed -n 's/^overlay_prefix=//p' "$ENV"); PFX=${PFX:-sun50i-h616}
ODIR=$(dirname "$(find "$MNT/boot" -name "${PFX}-uart5.dtbo" | head -n1)")
[ -f "$ODIR/${PFX}-uart5.dtbo" ] || { echo "Overlay ${PFX}-uart5.dtbo fehlt!"; exit 1; }
if grep -q '^overlays=' "$ENV"; then
  grep -qE '^overlays=.*\buart5\b' "$ENV" || sed -i -E 's/^overlays=(.*)$/overlays=\1 uart5/; s/^overlays= /overlays=/' "$ENV"
else
  echo "overlays=uart5" >> "$ENV"
fi
grep -q '^overlay_prefix=' "$ENV" || echo "overlay_prefix=$PFX" >> "$ENV"
FDT=$(sed -n 's/^fdtfile=//p' "$ENV")
DTB=$(find "$MNT/boot" -path "*${FDT:-sun50i-h618-orangepi-zero2w.dtb}" | head -n1)
[ -n "$DTB" ] || DTB=$(find "$MNT/boot" -name 'sun50i-h618-orangepi-zero2w.dtb' | head -n1)
echo "DTB: ${DTB#$MNT}"
dtc -q -I dtb -O dts "$DTB" > "$B/board.dts"
USBNODE=$(awk '/usb@5100000 \{/{f=1; d=0} f{ if (/dr_mode/) {print; exit} d+=gsub(/\{/,"{"); d-=gsub(/\}/,"}"); if (d<=0) exit }' "$B/board.dts")
echo "OTG-Port usb@5100000: ${USBNODE:-kein dr_mode}"
DRM=$(echo "$USBNODE" | sed -n 's/.*dr_mode = "\([a-z]*\)".*/\1/p')
if [ "$DRM" = host ] || [ -z "$DRM" ]; then
  say "OTG steht auf '${DRM:-?}' → Overlay lr2021-otg (peripheral)"
  mkdir -p "$SRC/overlay" "$MNT/boot/overlay-user"
  cat > "$SRC/overlay/lr2021-otg.dts" <<'DTS'
/dts-v1/;
/plugin/;
/ {
	compatible = "allwinner,sun50i-h616";
	fragment@0 {
		target-path = "/soc/usb@5100000";
		__overlay__ {
			dr_mode = "peripheral";
		};
	};
};
DTS
  dtc -q -@ -I dts -O dtb -o "$MNT/boot/overlay-user/lr2021-otg.dtbo" "$SRC/overlay/lr2021-otg.dts"
  if grep -q '^user_overlays=' "$ENV"; then
    grep -q 'lr2021-otg' "$ENV" || sed -i -E 's/^user_overlays=(.*)$/user_overlays=\1 lr2021-otg/' "$ENV"
  else
    echo "user_overlays=lr2021-otg" >> "$ENV"
  fi
fi
# Eigene Overlays (Quellen in source/overlay):
#  lr2021-nothermal: Kernel 6.18.60 (trunk) misst auf dem Zero 2W 150-260 °C bei kaltem Board
#                    -> sofortige Notabschaltung nach dem Kernelstart; Sensor abschalten
#  lr2021-uart34:    UART3 (PI9/PI10, ttyS3, ESP32 A) und UART4 (PI13/PI14, ttyS4, ESP32 B);
#                    der Kernel-DT hat dafür function="uart2", Armbians uart4-pi-Overlay schaltet uart3 ein
LR_OVERLAYS="lr2021-nothermal lr2021-uart34"
mkdir -p "$MNT/boot/overlay-user"
for o in $LR_OVERLAYS; do
  say "Overlay $o"
  dtc -q -@ -I dts -O dtb -o "$MNT/boot/overlay-user/$o.dtbo" "$SRC/overlay/$o.dts"
  cp "$MNT/boot/overlay-user/$o.dtbo" "$SRC/overlay/$o.dtbo"
  if grep -q '^user_overlays=' "$ENV"; then
    grep -qE "^user_overlays=.*\b$o\b" "$ENV" || sed -i -E "s/^user_overlays=(.*)\$/user_overlays=\1 $o/" "$ENV"
  else
    echo "user_overlays=$o" >> "$ENV"
  fi
done
# Overlays testweise auf die Board-DTB anwenden (wie U-Boot) und Ergebnis merken
OV_ARGS=""; for o in $LR_OVERLAYS; do OV_ARGS="$OV_ARGS $MNT/boot/overlay-user/$o.dtbo"; done
fdtoverlay -i "$DTB" -o "$B/merged.dtb" "$ODIR/${PFX}-uart5.dtbo" $OV_ARGS
dtc -q -I dtb -O dts "$B/merged.dtb" > "$B/merged.dts"
echo "--- armbianEnv.txt neu:"; cat "$ENV"
cp "$ENV" "$SRC/referenz/armbianEnv.txt"

# ------------------------------------------------------------------ Benutzer, Hostname, Dienste
say "Benutzer, Hostname, Dienste"
in_chroot '
set -e
for g in sudo dialout netdev bluetooth plugdev; do getent group $g >/dev/null || groupadd -r $g; done
id lr2021 >/dev/null 2>&1 || useradd -m -s /bin/bash lr2021
usermod -aG sudo,dialout,netdev,bluetooth,plugdev lr2021
echo "lr2021:lr2021node" | chpasswd
echo "root:lr2021node" | chpasswd
rm -f /root/.not_logged_in_yet
# Armbians root-Autologin auf Konsolen entfernen (sonst root-Shell auch über den USB-COM-Port)
rm -f /etc/systemd/system/serial-getty@.service.d/override.conf /etc/systemd/system/getty@.service.d/override.conf
rmdir /etc/systemd/system/getty@.service.d 2>/dev/null || true
echo lr2021-node > /etc/hostname
sed -i "/127.0.1.1/d" /etc/hosts; echo "127.0.1.1 lr2021-node" >> /etc/hosts
systemctl enable NetworkManager avahi-daemon bluetooth nftables ssh lr2021-firstboot lr2021-usb-gadget lr2021-hotspot lr2021d serial-getty@ttyGS0.service
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
systemctl disable systemd-networkd.service systemd-networkd.socket 2>/dev/null || true
systemctl mask systemd-networkd-wait-online.service
if systemctl is-enabled systemd-resolved >/dev/null 2>&1; then
  systemctl disable systemd-resolved; echo "systemd-resolved deaktiviert (NetworkManager schreibt resolv.conf)"
fi
systemctl disable armbian-firstlogin 2>/dev/null || true
for s in aw859a-wifi aw859a-bluetooth armbian-firstrun armbian-resize-filesystem; do
  printf "%-28s %s\n" $s "$(systemctl is-enabled $s 2>&1)"
done
'

# ------------------------------------------------------------------ Aufräumen
say "chroot aufräumen"
rm -f "$MNT/usr/sbin/policy-rc.d" "$MNT/usr/bin/qemu-aarch64-static"
rm -f "$MNT/etc/resolv.conf"
if [ -L "$MNT/etc/resolv.conf.lr2021-orig" ] && readlink "$MNT/etc/resolv.conf.lr2021-orig" | grep -q systemd/resolve \
   && [ ! -e "$MNT/etc/systemd/system/sysinit.target.wants/systemd-resolved.service" ] \
   && [ ! -e "$MNT/etc/systemd/system/multi-user.target.wants/systemd-resolved.service" ]; then
  rm -f "$MNT/etc/resolv.conf.lr2021-orig"; : > "$MNT/etc/resolv.conf"     # NetworkManager füllt sie
elif [ -e "$MNT/etc/resolv.conf.lr2021-orig" ] || [ -L "$MNT/etc/resolv.conf.lr2021-orig" ]; then
  mv "$MNT/etc/resolv.conf.lr2021-orig" "$MNT/etc/resolv.conf"
else
  : > "$MNT/etc/resolv.conf"
fi
rm -rf "$MNT/var/lib/apt/lists/"* "$MNT/var/cache/apt/"*.bin
find "$MNT/opt/lr2021" -name __pycache__ -prune -exec rm -rf {} +

# ------------------------------------------------------------------ 7. Prüfen
say "PRÜFUNGEN"
FAIL=0
chk() { if eval "$2" >/dev/null 2>&1; then echo "  OK    $1"; else echo "  FEHLT $1"; FAIL=1; fi; }
cp "$QEMU" "$MNT/usr/bin/qemu-aarch64-static"
for s in NetworkManager avahi-daemon bluetooth nftables ssh lr2021-firstboot lr2021-usb-gadget lr2021-hotspot lr2021d; do
  chk "Dienst $s enabled" "[ \"\$(chroot $MNT systemctl is-enabled $s)\" = enabled ]"
done
chk "serial-getty@ttyGS0 enabled" "[ -L $MNT/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service ]"
chk "networkd-wait-online aus" "! chroot $MNT systemctl is-enabled systemd-networkd-wait-online"
chk "aw859a-wifi aktiv" "[ \"\$(chroot $MNT systemctl is-enabled aw859a-wifi 2>/dev/null)\" = enabled ] || ! [ -e $MNT/lib/systemd/system/aw859a-wifi.service ]"
chk "py_compile (Debian-Python im Image)" "chroot $MNT python3 -m py_compile /opt/lr2021/lr2021d.py /opt/lr2021/lrmodem.py /opt/lr2021/serialbridge.py"
find "$MNT/opt/lr2021" -name __pycache__ -prune -exec rm -rf {} +
chk "nft -c -f /etc/nftables.conf" "nft -c -f $MNT/etc/nftables.conf"
chk "Keyfiles 600 root" "[ -z \"\$(find $MNT/etc/NetworkManager/system-connections -type f ! -perm 600)\" ]"
chk "armbianEnv: uart5" "grep -qE '^overlays=.*uart5' $ENV"
chk "uart5-Overlay vorhanden" "[ -f $ODIR/${PFX}-uart5.dtbo ]"
if grep -q lr2021-otg "$ENV"; then chk "OTG-Overlay vorhanden" "[ -f $MNT/boot/overlay-user/lr2021-otg.dtbo ]"; fi
chk "/root/.not_logged_in_yet weg" "[ ! -e $MNT/root/.not_logged_in_yet ]"
chk "node.json: ESP-UART 500000 Baud (H618 kann kein 460800)" "grep -q '\"uart_baud\": 500000' $MNT/etc/lr2021/node.json"
chk "kein root-Autologin" "! grep -rqs autologin $MNT/etc/systemd/system/serial-getty@.service.d $MNT/etc/systemd/system/getty@.service.d"
chk "Getty: feste Terminalgröße" "grep -q TTYRows $MNT/etc/systemd/system/serial-getty@.service.d/lr2021.conf"
chk "kein NetworkManager-Hotspot-Profil" "[ ! -e $MNT/etc/NetworkManager/system-connections/LR2021-Hotspot.nmconnection ]"
chk "udev: wlan0 nicht von NetworkManager" "grep -q 'NM_UNMANAGED}=\"1\"' $MNT/etc/udev/rules.d/91-lr2021-wlan.rules"
chk "wpa_supplicant + dnsmasq vorhanden" "[ -x $MNT/usr/sbin/wpa_supplicant ] && [ -x $MNT/usr/sbin/dnsmasq ]"
chk "Hotspot-Konfig: nur WPA-PSK, PMF aus" "chroot $MNT python3 /opt/lr2021/lr2021d.py -c /etc/lr2021/node.json --hotspot-conf /tmp/hs.conf && grep -q 'key_mgmt=WPA-PSK\$' $MNT/tmp/hs.conf && grep -q 'ieee80211w=0' $MNT/tmp/hs.conf && [ \"\$(stat -c %a $MNT/tmp/hs.conf)\" = 600 ]"
rm -f "$MNT/tmp/hs.conf"; find "$MNT/opt/lr2021" -name __pycache__ -prune -exec rm -rf {} +
chk "udev: usb0 von NetworkManager verwaltet" "grep -q 'NM_UNMANAGED}=\"0\"' $MNT/etc/udev/rules.d/90-lr2021-usb-gadget.rules"
for o in $LR_OVERLAYS; do
  chk "Overlay $o eingetragen" "[ -f $MNT/boot/overlay-user/$o.dtbo ] && grep -qE '^user_overlays=.*\b$o\b' $ENV"
done
# Device-Tree nach allen Overlays: Sensor aus, UART3/4/5 an, richtige Pin-Funktionen
dtnode() { awk -v n="$1" 'index($0, n" {"){f=1} f{print} f&&/^\t\t};/{exit}' "$B/merged.dts"; }
chk "DT: Temperatursensor aus" "dtnode thermal-sensor@5070400 | grep -q 'status = \"disabled\"'"
chk "DT: UART3 (ttyS3) an" "dtnode serial@5000c00 | grep -q 'status = \"okay\"'"
chk "DT: UART4 (ttyS4) an" "dtnode serial@5001000 | grep -q 'status = \"okay\"'"
chk "DT: UART5 (ttyS5) an" "dtnode serial@5001400 | grep -q 'status = \"okay\"'"
chk "DT: PI9/PI10 = uart3" "grep -A3 'lr2021-uart3-pins {' $B/merged.dts | grep -q 'function = \"uart3\"'"
chk "DT: PI13/PI14 = uart4" "grep -A3 'lr2021-uart4-pins {' $B/merged.dts | grep -q 'function = \"uart4\"'"
chk "Benutzer lr2021 (sudo,dialout)" "chroot $MNT id -nG lr2021 | grep -qw sudo && chroot $MNT id -nG lr2021 | grep -qw dialout"
chk "sdptool vorhanden" "[ -x $MNT/usr/bin/sdptool ]"
chk "esptool vorhanden" "chroot $MNT sh -c 'command -v esptool || command -v esptool.py'"
chk "nmcli vorhanden" "[ -x $MNT/usr/bin/nmcli ]"
chk "libcomposite in modules-load" "grep -q libcomposite $MNT/etc/modules-load.d/lr2021.conf"
KV=$(ls "$MNT/lib/modules" | head -n1)
chk "Kernel hat libcomposite ($KV)" "find $MNT/lib/modules/$KV -name 'libcomposite.ko*' | grep -q . || grep -q 'CONFIG_USB_LIBCOMPOSITE=y' $MNT/boot/config-$KV"
chk "Kernel hat usb_f_ncm" "find $MNT/lib/modules/$KV -name 'usb_f_ncm.ko*' | grep -q . || grep -q 'CONFIG_USB_F_NCM=y' $MNT/boot/config-$KV"
chk "Kernel hat usb_f_acm" "find $MNT/lib/modules/$KV -name 'usb_f_acm.ko*' | grep -q . || grep -q 'CONFIG_USB_F_ACM=y' $MNT/boot/config-$KV"
chk "Kernel hat musb (OTG)" "grep -qE 'CONFIG_USB_MUSB_SUNXI=(y|m)' $MNT/boot/config-$KV"
grep -E 'CONFIG_USB_MUSB_(HOST|GADGET|DUAL_ROLE)=y' "$MNT/boot/config-$KV" || true
rm -f "$MNT/usr/bin/qemu-aarch64-static"

say "lr2021d testweise starten (WSL, Ports > 1024)"
T=$(mktemp -d)
cp -r "$SRC/opt/lr2021" "$T/app"
cat > "$T/node.json" <<'JSON'
{"http_port": 18080, "tcp_port_a": 12021, "tcp_port_b": 12022, "tcp_port_gps": 12023,
 "bluetooth": false, "ports": ["/dev/null-kein-modem"], "gps_port": "", "admin_password": "test1234"}
JSON
python3 "$T/app/lr2021d.py" -c "$T/node.json" > "$T/log.txt" 2>&1 &
PID=$!
ok=0
for i in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:18080/api/status > "$T/status.json" 2>/dev/null; then ok=1; break; fi
  sleep 0.5
done
if [ $ok = 1 ]; then echo "  OK    /api/status:"; head -c 600 "$T/status.json"; echo; else echo "  FEHLT /api/status"; FAIL=1; fi
chk "Web / liefert index.html" "curl -fsS http://127.0.0.1:18080/ | grep -q 'LR2021 Node'"
chk "POST ohne Passwort → 401" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:18080/api/reboot)\" = 401 ]"
chk "TCP 12021 offen" "timeout 2 bash -c '</dev/tcp/127.0.0.1/12021'"
kill $PID 2>/dev/null; wait $PID 2>/dev/null || true
sed 's/^/    log: /' "$T/log.txt" | head -20
# Update-/Rollback-Logik mit Testverzeichnissen
mkdir -p "$T/pkg/lr2021" "$T/inst/lr2021"
cp "$SRC/opt/lr2021/"*.py "$T/pkg/lr2021/"; echo neu > "$T/pkg/lr2021/MARKE"; echo alt > "$T/inst/lr2021/MARKE"
cp "$SRC/opt/lr2021/lr2021d.py" "$T/inst/lr2021/"
tar -czf "$T/upd.tar.gz" -C "$T/pkg" lr2021
chk "Update-Logik (install_update + rollback)" "cd $T/app && python3 -c \"
import lr2021d as d
d.STATE_DIR='$T/state'
d.install_update(open('$T/upd.tar.gz','rb').read(), '$T/inst/lr2021', '$T/inst/lr2021.alt')
assert open('$T/inst/lr2021/MARKE').read().strip()=='neu'
assert open('$T/inst/lr2021.alt/MARKE').read().strip()=='alt'
d.rollback('$T/inst/lr2021', '$T/inst/lr2021.alt')
assert open('$T/inst/lr2021/MARKE').read().strip()=='alt'
\""
chk "Update lehnt ../-Pfade ab" "cd $T/app && python3 -c \"
import io, tarfile, lr2021d as d
d.STATE_DIR='$T/state'
b=io.BytesIO(); t=tarfile.open(fileobj=b, mode='w:gz'); i=tarfile.TarInfo('../x'); t.addfile(i, io.BytesIO(b'')); t.close()
try:
    d.install_update(b.getvalue(), '$T/inst/lr2021', '$T/inst/lr2021.alt'); raise SystemExit(1)
except ValueError: pass
\""
rm -rf "$T"

# ------------------------------------------------------------------ Aushängen
say "Freien Platz verwerfen, aushängen, prüfen"
fstrim -v "$MNT" || true
sync
for m in "$MNT/dev/pts" "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/run" "$MNT"; do umount "$m"; done
e2fsck -fy "$PART" || [ $? -le 1 ]
losetup -d "$LOOP"; LOOP=""

[ $FAIL = 0 ] || { echo; echo "!!! Mindestens eine Prüfung fehlgeschlagen – Image NICHT exportiert."; exit 3; }

# ------------------------------------------------------------------ Export
say "Image nach $NODE/image exportieren"
mkdir -p "$NODE/image"
cp --sparse=always "$IMG" "$NODE/image/$OUTNAME.img"
xz -T0 -6 -kf "$IMG"
mv "$IMG.xz" "$NODE/image/$OUTNAME.img.xz"
( cd "$NODE/image" && sha256sum "$OUTNAME.img" "$OUTNAME.img.xz" > "$OUTNAME.sha256" && cat "$OUTNAME.sha256" )
ls -la "$NODE/image"
echo; echo "BUILD FERTIG: $NODE/image/$OUTNAME.img"
