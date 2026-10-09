#!/usr/bin/env bash
# Installs asus-presence. Run as your desktop user (not root); system parts use sudo.
#
#   ./install.sh            install (or upgrade) and enable for the current user
#
# Installs under /usr/local. Undo with ./uninstall.sh.
set -euo pipefail
sudo() { command sudo ${SUDO_ASKPASS:+-A} "$@"; }
cd "$(dirname "$0")"

GROUP=asus-presence
PREFIX=/usr/local
SHARE="${PREFIX}/share"

say() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -ne 0 ]] || die "run this as your desktop user, not root (it uses sudo where needed)"

say "Checking requirements"
python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' || die "Python 3.8 or newer is required"
python3 -c 'import dbus' 2>/dev/null || die "python3-dbus is required (Debian/Ubuntu: python3-dbus, Fedora: python3-dbus, Arch: python-dbus)"
command -v gdbus >/dev/null || die "gdbus is required (part of GLib: libglib2.0-bin / glib2)"
modinfo hid_sensor_prox >/dev/null 2>&1 || warn "kernel module hid_sensor_prox not found; the sensor cannot work without it"
found=""
for dev in /sys/bus/iio/devices/iio:device*; do
  [[ -e "${dev}/scan_elements/in_attention_en" && "$(cat "${dev}/name" 2>/dev/null)" == prox ]] && found=1
done
[[ -n "${found}" ]] || warn "no presence sensor with an attention channel found (needs the webcam sensor and Linux 6.13+); installing anyway"
command -v plasmashell >/dev/null || warn "KDE Plasma not found: the sensor service works, but the lock/dim agent targets Plasma 6"
command -v kscreen-doctor >/dev/null || warn "kscreen-doctor not found: 'wake on return' will not work"
command -v swayidle >/dev/null || warn "swayidle not found: the optional \"only when idle\" setting needs it (apt install swayidle)"

say "Installing system files"
getent group "${GROUP}" >/dev/null || sudo groupadd --system "${GROUP}"
sudo install -o root -g root -m 755 asus-presence-sensord asus-presence-agent asus-presence-ctl "${PREFIX}/bin/"
sudo install -o root -g root -m 644 systemd/asus-presence.service /etc/systemd/system/
sudo install -o root -g root -m 644 systemd/asus-presence-agent.service /etc/systemd/user/
sudo install -d -o root -g root -m 755 "${SHARE}/asus-presence" "${SHARE}/doc/asus-presence" \
  "${SHARE}/plasma/plasmoids/asus-presence" "${SHARE}/applications"
sudo install -o root -g root -m 644 presence.conf.example "${SHARE}/asus-presence/"
sudo install -o root -g root -m 644 README.md "${SHARE}/doc/asus-presence/"
sudo cp -r ui/metadata.json ui/contents "${SHARE}/plasma/plasmoids/asus-presence/"
sudo chown -R root:root "${SHARE}/plasma/plasmoids/asus-presence"
sudo install -o root -g root -m 644 ui/asus-presence.desktop "${SHARE}/applications/"
sudo systemctl daemon-reload
sudo systemctl enable asus-presence.service
sudo systemctl restart asus-presence.service

say "Setting up ${USER}"
in_group=1
id -nG | tr ' ' '\n' | grep -qx "${GROUP}" || in_group=0
if ! id -nG "${USER}" | tr ' ' '\n' | grep -qx "${GROUP}"; then
  sudo usermod -aG "${GROUP}" "${USER}"
fi
install -d -m 700 "${HOME}/.config/asus-presence"
[[ -f "${HOME}/.config/asus-presence/presence.conf" ]] \
  || install -m 600 presence.conf.example "${HOME}/.config/asus-presence/presence.conf"
systemctl --user daemon-reload
systemctl --user enable asus-presence-agent.service
if [[ ${in_group} -eq 1 ]]; then
  systemctl --user restart asus-presence-agent.service
  say "Done. Open \"Presence Sensor\" from the launcher to see it live."
else
  say "Done. Log out and back in once (to join the ${GROUP} group); the agent then starts by itself."
fi
