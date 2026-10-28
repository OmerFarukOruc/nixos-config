# shellcheck shell=bash
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

runs_tree_of() {
  local revision dirty action
  read -r revision dirty action <<<"$(running_revision)" || true
  [[ -n $revision && $dirty == false && $action != test ]] || return 1
  [[ $(git rev-parse -q --verify "$revision^{tree}") == "$(git rev-parse "$1^{tree}")" ]]
}
