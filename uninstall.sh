#!/usr/bin/env bash
# Removes asus-presence. Run as your desktop user (not root).
#
#   ./uninstall.sh           remove the program; keep your settings
#   ./uninstall.sh --purge   also remove ~/.config/asus-presence and ~/.cache/asus-presence
set -euo pipefail
sudo() { command sudo ${SUDO_ASKPASS:+-A} "$@"; }

GROUP=asus-presence
PREFIX=/usr/local
SHARE="${PREFIX}/share"
purge=0
[[ "${1:-}" == "--purge" ]] && purge=1

[[ ${EUID} -ne 0 ]] || { echo "run this as your desktop user, not root" >&2; exit 1; }

echo "==> Stopping"
command -v asus-presence-ctl >/dev/null && asus-presence-ctl tray off >/dev/null 2>&1 || true
systemctl --user disable --now asus-presence-agent.service 2>/dev/null || true
sudo systemctl disable --now asus-presence.service 2>/dev/null || true

echo "==> Removing files"
sudo rm -f "${PREFIX}/bin/asus-presence-sensord" "${PREFIX}/bin/asus-presence-agent" "${PREFIX}/bin/asus-presence-ctl" \
  /etc/systemd/system/asus-presence.service /etc/systemd/user/asus-presence-agent.service \
  "${SHARE}/applications/asus-presence.desktop"
sudo rm -rf "${SHARE}/asus-presence" "${SHARE}/doc/asus-presence" "${SHARE}/plasma/plasmoids/asus-presence" \
  /run/asus-presence
sudo systemctl daemon-reload
systemctl --user daemon-reload
getent group "${GROUP}" >/dev/null && sudo groupdel "${GROUP}"

if [[ ${purge} -eq 1 ]]; then
  rm -rf "${HOME}/.config/asus-presence" "${HOME}/.cache/asus-presence"
  echo "==> Removed, including your settings."
else
  echo "==> Removed. Your settings are kept in ~/.config/asus-presence (use --purge to remove them)."
fi
echo "    Other users who enabled the agent: systemctl --user disable asus-presence-agent"
