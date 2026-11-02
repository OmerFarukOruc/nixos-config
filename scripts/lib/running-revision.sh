# shellcheck shell=bash
running_revision() {
  local system record installed=/var/lib/nixos-upgrade/installed
  system=$(readlink -f /run/current-system)
  if [[ -r $installed ]] && grep -qxF "system=$system" "$installed"; then
    printf '%s false switch main\n' "$(sed -n 's/^revision=//p' "$installed")"
    return
  fi
  for record in "$HOME"/.local/state/nixos-config-deploy/releases/*.source; do
    if grep -qxF "system=$system" "$record" 2>/dev/null; then
      printf '%s %s %s %s\n' "$(sed -n 's/^revision=//p' "$record")" "$(sed -n 's/^dirty=//p' "$record")" \
        "$(sed -n 's/^action=//p' "$record")" "$(sed -n 's/^branch=//p' "$record")"
    fi
  done | tail -n 1
}
