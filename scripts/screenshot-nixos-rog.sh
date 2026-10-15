#!/usr/bin/env bash
# usage: scripts/screenshot-nixos-rog.sh [--window] [--crop WxH+X+Y] OUTPUT.png
# Takes a full-screen screenshot of the Plasma session on nixos-rog and copies
# it to OUTPUT. --window first opens a Ghostty window that is not maximized,
# so the shot shows the Glass blur and edges around it, and closes it after.
# --crop keeps only the area of W by H pixels at X, Y, in the screen's pixels;
# 2560x60+0+0 holds the top bar on nixos-rog's 2560x1600 screen.
set -euo pipefail

usage="usage: scripts/screenshot-nixos-rog.sh [--window] [--crop WxH+X+Y] OUTPUT.png"
window=false
crop=
while [[ ${1:-} == --* ]]; do
  case $1 in
    --window) window=true ;;
    --crop)
      if [[ ! ${2:-} =~ ^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$ ]]; then
        echo "$usage" >&2
        exit 2
      fi
      crop=$2
      shift
      ;;
    *)
      echo "$usage" >&2
      exit 2
      ;;
  esac
  shift
done
if (($# != 1)); then
  echo "$usage" >&2
  exit 2
fi
out=$1

# stdout carries the PNG, so everything else on the host writes to stderr.
status=0
ssh -o ConnectTimeout=15 -o BatchMode=yes nixos-rog "bash -s -- $(printf '%q ' "$window" "$crop")" <<'EOF' >"$out" || status=$?
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
if [[ -n ${2:-} ]]; then
  # The flake registry pins nixpkgs to the running system's, so this needs no
  # download of nixpkgs, only of ImageMagick on its first use.
  size=$(nix run nixpkgs#imagemagick -- "$dir/shot.png" -crop "$2" +repage \
    -write "$dir/crop.png" -format '%wx%h' info: </dev/null)
  # ImageMagick only warns about an area outside the screen and exits 0, so
  # the size of the result is checked.
  if [[ $size != "${2%%+*}" ]]; then
    echo "The crop $2 got $size pixels; it must lie inside the screen." >&2
    exit 1
  fi
  mv -- "$dir/crop.png" "$dir/shot.png"
fi
cat "$dir/shot.png"
EOF
if ((status)); then
  rm -f -- "$out"
  exit "$status"
fi
