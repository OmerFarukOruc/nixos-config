#!/usr/bin/env bash
workspace=$HOME/Desktop/workspace
report_dir=/tmp/agents/worktree-sweep
state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/worktree-sweep
draft=
failed=()

finish() {
  local code=$?
  [ -z "$draft" ] || rm -f "$draft"
  if ((code)); then
    mkdir -p "$state_dir"
    printf 'the run at %s exited %s, see %s/report.md and journalctl --user -u worktree-sweep\n' \
      "$(date -u +%FT%TZ)" "$code" "$report_dir" >"$state_dir/failed"
  else
    rm -f "$state_dir/failed"
  fi
}
trap finish EXIT

sweep() {
  local repo=$1 pruned
  shift
  printf '\n## %s\n\n' "${repo##*/}"
  if git -C "$repo" remote get-url origin >/dev/null 2>&1 && ! git -C "$repo" fetch --quiet --prune origin; then
    printf -- '- fetch failed, so prune measured merges against the local refs\n'
  fi
  pruned=$(wt -C "$repo" step prune --foreground --format=json "$@" </dev/null) || return 1
  jq -r '.[]
    | (if has("branch_outcome") then "removed" else "would remove" end) as $verb
    | "- \($verb) \(.path // .pruned // "branch only") (\(.branch // "detached HEAD"), branch \(.branch_outcome // (if .branch_deleted then "deleted" else "kept" end)))"' \
    <<<"$pruned" || return 1
  wt -C "$repo" list --format=json </dev/null | jq -r '
    [.items[]
      | select(.worktree != null and .worktree.main == false)
      | "- kept \(.worktree.path) (\(.branch // "detached HEAD"), \(.display.state // "unknown")"
        + (if [.worktree.changes | del(.diff)[]] | any then ", uncommitted changes)" else ")" end)]
    | if length == 0 then "- no linked worktrees" else .[] end' || return 1
}

mkdir -p "$report_dir"
draft=$(mktemp "$report_dir/.report.XXXXXX")
printf '# Worktree sweep on %s at %s\n' "$(uname -n)" "$(date -u +%FT%TZ)" >"$draft"
for git_dir in "$workspace"/*/.git; do
  [ -d "$git_dir" ] || continue
  repo=${git_dir%/.git}
  if ! sweep "$repo" "$@" >>"$draft"; then
    failed+=("${repo##*/}")
    printf -- '- sweep failed, see journalctl --user -u worktree-sweep\n' >>"$draft"
  fi
done
mv "$draft" "$report_dir/report.md"
draft=
cat "$report_dir/report.md"

if ((${#failed[@]})); then
  echo "worktree sweep failed in: ${failed[*]}" >&2
  exit 1
fi
