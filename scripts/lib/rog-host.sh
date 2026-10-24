# shellcheck shell=bash disable=SC2034 # the scripts that source this file read ROG_HOST and ROG_LOCAL
# Sourced by the scripts that run Nix on nixos-rog (scripts/lib/rog-copy.sh,
# scripts/affected-hosts.sh). nixos-rog is a laptop and is often off, and SSH
# to an offline Tailscale peer fails only after about two minutes.
ROG_HOST=nixos-rog
ROG_LOCAL=0

# rog_pick_host [--no-local]: sets ROG_LOCAL=1 when the work runs on this host
# instead of over SSH: on nixos-rog itself, or on nixos-desktop while Tailscale
# reports nixos-rog offline. nixos-desktop has the same 30 GiB of memory and
# the same heavy, so the work fits there too. When nixos-rog is offline and
# this host cannot stand in, or --no-local forbids it, it exits 1 at once.
# When Tailscale cannot tell, it leaves the choice to SSH.
rog_pick_host() {
  local this online
  this=$(</proc/sys/kernel/hostname)
  if [[ $this == "$ROG_HOST" ]]; then
    ROG_LOCAL=1
    return 0
  fi
  online=$(tailscale status --json 2>/dev/null |
    jq -r --arg h "$ROG_HOST" '[.Peer[]? | select(.HostName == $h) | .Online | tostring] | first // "unknown"' 2>/dev/null) ||
    online=unknown
  [[ $online == false ]] || return 0
  if [[ ${1:-} != --no-local && $this == nixos-desktop ]]; then
    echo "$ROG_HOST is offline (tailscale status); running on $this instead" >&2
    ROG_LOCAL=1
    return 0
  fi
  echo "$ROG_HOST is offline (tailscale status)" >&2
  exit 1
}
