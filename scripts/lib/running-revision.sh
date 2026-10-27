# shellcheck shell=bash
# Sourced by upgrade (nixosModules/upgrade.nix), scripts/pull-main.sh and
# scripts/self-deploy.sh from their clones of main; scripts/affected-hosts.sh sends it ahead of the script it
# runs on each host over SSH.
# running_revision: prints "<revision> <dirty> <action>" from the release record
# whose system= line names the running system (docs/deploy.md, Release records
# and cleanup), or nothing when no record names it. When several records name
# it, the newest one counts.
running_revision() {
  local system record
  system=$(readlink -f /run/current-system)
  for record in "$HOME"/.local/state/nixos-config-deploy/releases/*.source; do
    if grep -qxF "system=$system" "$record" 2>/dev/null; then
      printf '%s %s %s\n' "$(sed -n 's/^revision=//p' "$record")" "$(sed -n 's/^dirty=//p' "$record")" \
        "$(sed -n 's/^action=//p' "$record")"
    fi
  done | tail -n 1
}

# runs_tree_of REV: succeeds when this host runs a clean release whose commit
# has the tree of REV. A squash merge makes a new commit with the tree of the
# commit a host deployed. A test deploy leaves the boot default behind,
# so it does not count. Run it in a clone that holds both commits.
runs_tree_of() {
  local revision dirty action
  read -r revision dirty action <<<"$(running_revision)" || true
  [[ -n $revision && $dirty == false && $action != test ]] || return 1
  [[ $(git rev-parse -q --verify "$revision^{tree}") == "$(git rev-parse "$1^{tree}")" ]]
}
