# shellcheck shell=bash
workspace=$HOME/Desktop/workspace
report_dir=/tmp/agents/worktree-sweep
mkdir -p "$report_dir"
draft=$(mktemp "$report_dir/.report.XXXXXX")
failed=()

printf '# Worktree sweep on %s at %s\n' "$(uname -n)" "$(date -u +%FT%TZ)" >"$draft"
for git_dir in "$workspace"/*/.git; do
  [ -d "$git_dir" ] || continue
  repo=${git_dir%/.git}
  {
    printf '\n## %s\n\n' "${repo##*/}"
    if git -C "$repo" remote get-url origin >/dev/null 2>&1 && ! git -C "$repo" fetch --quiet --prune origin; then
      printf -- '- fetch failed, so prune measured merges against the local refs\n'
    fi
    if removed=$(wt -C "$repo" step prune --foreground --format=json "$@" </dev/null); then
      jq -r '.[] | "- removed \(.path // .pruned) (\(.branch // "detached HEAD"), branch \(.branch_outcome))"' <<<"$removed"
    else
      failed+=("${repo##*/}")
      printf -- '- prune failed, see journalctl --user -u worktree-sweep\n'
    fi
    wt -C "$repo" list --format=json </dev/null | jq -r '
      [.items[]
        | select(.worktree != null and .worktree.main == false)
        | "- kept \(.worktree.path) (\(.branch // "detached HEAD"), \(.display.state // "unknown")"
          + (if [.worktree.changes | del(.diff)[]] | any then ", uncommitted changes)" else ")" end)]
      | if length == 0 then "- no linked worktrees" else .[] end'
  } >>"$draft"
done
mv "$draft" "$report_dir/report.md"
cat "$report_dir/report.md"

if ((${#failed[@]})); then
  echo "wt step prune failed in: ${failed[*]}" >&2
  exit 1
fi
