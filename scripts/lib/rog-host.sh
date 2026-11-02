# shellcheck shell=bash disable=SC2034 # scripts/lib/work-copy.sh reads ROG_HOST and ROG_LOCAL
# shellcheck source=/dev/null
. "${BASH_SOURCE[0]%/*}/ssh.sh"
ROG_HOST=nixos-rog
ROG_LOCAL=0

rog_pick_host() {
  local online
  if [[ $(</proc/sys/kernel/hostname) == "$ROG_HOST" ]]; then
    ROG_LOCAL=1
    return 0
  fi
  online=$(timeout 5 tailscale status --json 2>/dev/null |
    jq -r --arg h "$ROG_HOST" '[.Peer[]? | select(.HostName == $h) | .Online | tostring] | first // "unknown"' 2>/dev/null) ||
    online=unknown
  [[ $online == false ]] || return 0
  echo "$ROG_HOST is offline (tailscale status)" >&2
  exit 1
}

# rog_session_script [--wayland]: prints the start of a remote script that
# reaches the login session's user bus, and with --wayland its Wayland socket.
rog_session_script() {
  cat <<'EOF'
set -euo pipefail
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
EOF
  [[ ${1:-} == --wayland ]] || return 0
  cat <<'EOF'
# The login session exports its Wayland socket name to the user's systemd
# manager; the name depends on how many compositors started before it.
WAYLAND_DISPLAY=$(systemctl --user show-environment | sed -n 's/^WAYLAND_DISPLAY=//p')
if [[ -z $WAYLAND_DISPLAY ]]; then
  echo "No Wayland session runs on nixos-rog; log in first." >&2
  exit 1
fi
export WAYLAND_DISPLAY
EOF
}
