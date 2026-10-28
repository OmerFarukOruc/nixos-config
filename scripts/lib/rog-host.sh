# shellcheck shell=bash disable=SC2034 # scripts/lib/work-copy.sh reads ROG_HOST and ROG_LOCAL
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
