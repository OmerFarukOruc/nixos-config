#!/usr/bin/env bash
# usage: ci/agents-checks.sh HEAD PATH...
# Lints and parses each agents/ PATH as HEAD holds it, so uncommitted edits in the checkout do not count. For each mod
# under agents/claude/mods that a PATH is in, it runs `claude plugin validate`, and `claude plugin test` when the mod has
# a tests folder, on a copy of agents/ as HEAD holds it, with HOME and CLAUDE_CONFIG_DIR in a scratch folder.
set -euo pipefail
cd "$(dirname "$0")/.."

head=${1:?usage: ci/agents-checks.sh HEAD PATH...}
shift
failed=0
declare -A mods=()

fail() {
  echo "agents-checks: $*" >&2
  failed=1
}

for path in "$@"; do
  git cat-file -e "$head:$path" 2>/dev/null || continue
  if [[ $path == agents/claude/mods/*/* ]]; then
    mod=${path#agents/claude/mods/}
    mods[${mod%%/*}]=1
  fi
  case $path in
    *.sh) git show "$head:$path" | shellcheck --format=gcc - || fail "shellcheck reported $path" ;;
    *.py) git show "$head:$path" | ruff check --quiet --output-format=concise --stdin-filename="$path" - ||
      fail "ruff reported $path" ;;
    *.json) git show "$head:$path" | jq empty 2>/dev/null || fail "$path is not valid JSON" ;;
    *.toml) git show "$head:$path" | python3 -c 'import sys, tomllib; tomllib.load(sys.stdin.buffer)' 2>/dev/null ||
      fail "$path is not valid TOML" ;;
  esac
done

if ((${#mods[@]})); then
  scratch=$(mktemp -d)
  trap 'rm -rf -- "$scratch"' EXIT
  mkdir "$scratch/copy"
  git archive "$head" agents | tar -x -C "$scratch/copy"
  for mod in "${!mods[@]}"; do
    dir=$scratch/copy/agents/claude/mods/$mod
    [[ -f $dir/.claude-plugin/plugin.json ]] || continue
    for step in validate test; do
      [[ $step == validate || -d $dir/tests ]] || continue
      HOME=$scratch/home CLAUDE_CONFIG_DIR=$scratch/claude claude plugin "$step" "$dir" >"$scratch/$step.log" 2>&1 || {
        tail -n 40 "$scratch/$step.log" >&2
        fail "claude plugin $step failed for agents/claude/mods/$mod"
      }
    done
  done
fi

exit "$failed"
