# shellcheck shell=bash disable=SC2034 # scripts/lib/work-copy.sh reads ROG_HOST and ROG_LOCAL
# Sourced by the scripts that act on nixos-rog itself, directly or through
# scripts/lib/work-copy.sh. nixos-rog is a laptop and is often off, and one SSH
# call to it fails only after its 15 s connect timeout.
ROG_HOST=nixos-rog
ROG_LOCAL=0

# rog_pick_host: sets ROG_LOCAL=1 on nixos-rog itself, so the work runs
# without SSH. On another host it exits 1 at once while Tailscale reports
# nixos-rog offline. When Tailscale cannot tell within 5 s, it leaves the
# answer to SSH.
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
