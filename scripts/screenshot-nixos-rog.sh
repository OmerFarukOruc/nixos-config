#!/usr/bin/env bash
# usage: scripts/screenshot-nixos-rog.sh [--window] OUTPUT.png
# Takes a full-screen screenshot of the Plasma session on nixos-rog and copies
# it to OUTPUT. --window first opens a Ghostty window that is not maximized,
# so the shot shows the Glass blur and edges around it, and closes it after.
set -euo pipefail

window=false
if [[ ${1:-} == --window ]]; then
  window=true
  shift
fi
out=${1:?usage: scripts/screenshot-nixos-rog.sh [--window] OUTPUT.png}

# stdout carries the PNG, so everything else on the host writes to stderr.
status=0
ssh -o ConnectTimeout=15 -o BatchMode=yes nixos-rog bash -s -- "$window" <<'EOF' >"$out" || status=$?
set -euo pipefail
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
dir=$(mktemp -d /tmp/screenshot.XXXXXX)
cleanup() {
  if [[ -n ${pid:-} ]]; then kill "$pid" 2>/dev/null || true; fi
  rm -rf -- "$dir"
}
trap cleanup EXIT
if [[ $1 == true ]]; then
  # Without --gtk-single-instance=false, the window joins a running Ghostty
  # and has no process of its own to stop.
  ghostty --gtk-single-instance=false --window-width=90 --window-height=28 >/dev/null 2>&1 &
  pid=$!
  sleep 4
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "Ghostty exited before the screenshot." >&2
    exit 1
  fi
fi
spectacle --background --nonotify --fullscreen --output "$dir/shot.png" >&2
cat "$dir/shot.png"
EOF
if ((status)); then
  rm -f -- "$out"
  exit "$status"
fi
