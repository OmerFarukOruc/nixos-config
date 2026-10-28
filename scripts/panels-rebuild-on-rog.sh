#!/usr/bin/env bash
# usage: scripts/panels-rebuild-on-rog.sh
# Builds the Plasma panels on nixos-rog as the next login would, without a
# logout: ksystemstats and plasmashell start fresh in login order, and then
# plasma-manager deletes the panel file and builds the panels again. It first
# copies the panel files to ~/.local/state/panels-rebuild/<time>/ and prints
# that directory; to undo, stop plasma-plasmashell, copy the files back and
# start it. The build drops every panel change made in Plasma's settings since
# the last build, so ask Omer before you run it to clear a failed
# plasma-panel-settings check. Exits 1 when no Plasma session runs or the
# rebuild fails.
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/rog-host.sh"
if (($#)); then
  echo "usage: $0" >&2
  exit 64
fi

rog_pick_host
ssh -o ConnectTimeout=15 -o BatchMode=yes nixos-rog bash -s <<'EOF'
set -euo pipefail
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
# The login session exports its Wayland socket name to the user's systemd
# manager; the name depends on how many compositors started before it.
WAYLAND_DISPLAY=$(systemctl --user show-environment | sed -n 's/^WAYLAND_DISPLAY=//p')
if [[ -z $WAYLAND_DISPLAY ]]; then
  echo "No Wayland session runs on nixos-rog; log in first." >&2
  exit 1
fi
export WAYLAND_DISPLAY
if [[ $(systemctl --user show -p MainPID --value plasma-plasmashell) == 0 ]]; then
  echo "No Plasma session runs on nixos-rog; log in to Plasma first." >&2
  exit 1
fi

backup=$HOME/.local/state/panels-rebuild/$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$backup"
cp ~/.config/plasma-org.kde.plasma.desktop-appletsrc ~/.config/plasmashellrc "$backup/"
echo "Backup: $backup"

manager=$HOME/.local/share/plasma-manager
rm -f "$manager/last_run_desktop_script_panels"
systemctl --user stop plasma-plasmashell
systemctl --user restart plasma-ksystemstats
systemctl --user start plasma-plasmashell
for _ in {1..20}; do
  qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript 'print(1)' >/dev/null 2>&1 && break
  sleep 1
done
"$manager/run_all.sh"
# The panel script exits 0 even when plasmashell rejects it, and writes its
# last-run record only after a success.
if [[ ! -e $manager/last_run_desktop_script_panels ]]; then
  echo "plasma-manager's panel script failed, so the panels may be missing." >&2
  echo "To put the old panels back, stop plasma-plasmashell, copy the files from $backup to ~/.config and start it." >&2
  exit 1
fi

for dev in /sys/bus/pci/devices/*; do
  if [[ $(<"$dev/vendor") == 0x10de && $(<"$dev/class") == 0x030* ]]; then
    nvidia=$dev
    break
  fi
done
status=none
if [[ -n ${nvidia:-} ]]; then
  for _ in {1..30}; do
    status=$(<"$nvidia/power/runtime_status")
    [[ $status == suspended ]] && break
    sleep 1
  done
fi
echo "plasmashell: $(systemctl --user is-active plasma-plasmashell)"
echo "nvidia-smi processes: $(pgrep -c -x nvidia-smi || true)"
echo "RTX 4070: $status"
echo "Run scripts/verify-nixos-rog.sh next."
systemctl --user is-active --quiet plasma-plasmashell
EOF
