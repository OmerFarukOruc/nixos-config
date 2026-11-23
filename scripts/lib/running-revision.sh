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

install_skip_cause() {
  local git_dir=$1 main=$2 revision=$3 dirty=$4 action=$5 branch=${6:-a branch}
  [[ -n $revision ]] || return 1
  if [[ $dirty == true || $action == test ]]; then
    printf 'a %s deploy of %s at %s%s\n' "$action" "$branch" "${revision:0:12}" "$([[ $dirty == true ]] && echo ' from a dirty tree')"
  elif ! git -C "$git_dir" merge-base --is-ancestor "$revision" "$main" 2>/dev/null; then
    printf '%s at %s, which main lacks\n' "$branch" "${revision:0:12}"
  else
    return 1
  fi
}
