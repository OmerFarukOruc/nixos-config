#!/usr/bin/env bash
# usage: scripts/screenshot-nixos-rog.sh [--window] [--crop WxH+X+Y] OUTPUT.png
# Takes a full-screen screenshot of the Plasma session on nixos-rog and copies
# it to OUTPUT. --window first opens a Ghostty window that is not maximized,
# so the shot shows the Glass blur and edges around it, and closes it after.
# --crop keeps only the area of W by H pixels at X, Y, in the screen's pixels;
# 2560x60+0+0 holds the top 60 rows of nixos-rog's 2560x1600 screen. The crop
# runs on the calling host, so no Nix runs on the laptop.
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/rog-host.sh"

usage="usage: scripts/screenshot-nixos-rog.sh [--window] [--crop WxH+X+Y] OUTPUT.png"
window=false
crop=
while [[ ${1:-} == --* ]]; do
  case $1 in
    --window) window=true ;;
    --crop)
      if [[ ! ${2:-} =~ ^[1-9][0-9]*x[1-9][0-9]*\+[0-9]+\+[0-9]+$ ]]; then
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

if [[ -n $crop ]] && ! command -v nix >/dev/null; then
  echo "--crop runs ImageMagick through nix on this host, and nix is not on PATH." >&2
  exit 1
fi
rog_pick_host
status=0
ssh -o ConnectTimeout=15 -o BatchMode=yes nixos-rog "bash -s -- $(printf '%q ' "$window")" <<'EOF' >"$out" || status=$?
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
dir=$(mktemp -d /tmp/screenshot.XXXXXX)
cleanup() {
  if [[ -n ${pid:-} ]]; then kill "$pid" 2>/dev/null || true; fi
  rm -rf -- "$dir"
}
trap cleanup EXIT
if [[ $1 == true ]]; then
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
if [[ -n $crop ]]; then
  cropped=$(mktemp "$out.XXXXXX")
  trap 'rm -f -- "$cropped"' EXIT
  size=$(nix run nixpkgs#imagemagick -- "png:$out" -crop "$crop" +repage \
    -write "png:$cropped" -format '%wx%h' info: </dev/null) || status=$?
  # ImageMagick only warns about an area outside the screen and exits 0, so
  # the size of the result is checked.
  if ((status == 0)) && [[ $size != "${crop%%+*}" ]]; then
    echo "The crop $crop got $size pixels; it must lie inside the screen." >&2
    status=1
  fi
  if ((status)); then
    rm -f -- "$out"
    exit "$status"
  fi
  cat -- "$cropped" >"$out"
fi
