# shellcheck shell=bash
# Sourced by upgrade (nixosModules/upgrade.nix) and scripts/auto-update.sh from
# their clones of main; scripts/affected-hosts.sh sends it ahead of the script it
# runs on each host over SSH.
# running_revision: prints "<revision> <dirty>" from the release record whose
# system= line names the running system (docs/deploy.md, Release records and
# cleanup), or nothing when no record names it. When several records name it,
# the newest one counts.
running_revision() {
  local system record
  system=$(readlink -f /run/current-system)
  for record in "$HOME"/.local/state/nixos-config-deploy/releases/*.source; do
    if grep -qxF "system=$system" "$record" 2>/dev/null; then
      printf '%s %s\n' "$(sed -n 's/^revision=//p' "$record")" "$(sed -n 's/^dirty=//p' "$record")"
    fi
  done | tail -n 1
}
