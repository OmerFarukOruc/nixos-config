#!/usr/bin/env bash
# usage: ci/agents-checks.sh HEAD PATH...
# Lints and parses each agents/ PATH as HEAD holds it, so uncommitted edits in the checkout do not count. When a PATH,
# deleted ones included, is under agents/claude/mods or agents/skills, which a mod can link to, it runs
# `claude plugin validate` on each mod HEAD holds, and `claude plugin test` on each that has a tests folder.
set -euo pipefail
cd "$(dirname "$0")/.."

head=${1:?usage: ci/agents-checks.sh HEAD PATH...}
shift
failed=0
mods=false

fail() {
  echo "agents-checks: $*" >&2
  failed=1
}

for path in "$@"; do
  if [[ $path == agents/claude/mods/* || $path == agents/skills/* ]]; then mods=true; fi
  git cat-file -e "$head:$path" 2>/dev/null || continue
  case $path in
    *.sh) git show "$head:$path" | shellcheck --format=gcc - || fail "shellcheck reported $path" ;;
    *.py) git show "$head:$path" | ruff check --quiet --output-format=concise --stdin-filename="$path" - ||
      fail "ruff reported $path" ;;
    *.json) git show "$head:$path" | jq empty 2>/dev/null || fail "$path is not valid JSON" ;;
    *.toml) git show "$head:$path" | python3 -c 'import sys, tomllib; tomllib.load(sys.stdin.buffer)' 2>/dev/null ||
      fail "$path is not valid TOML" ;;
  esac
done

if $mods; then
  scratch=$(mktemp -d)
  trap 'rm -rf -- "$scratch"' EXIT
  mkdir "$scratch/copy"
  git archive "$head" agents | tar -x -C "$scratch/copy"
  for dir in "$scratch"/copy/agents/claude/mods/*/; do
    mod=agents/claude/mods/$(basename "$dir")
    for step in validate test; do
      [[ $step == validate || -d $dir/tests ]] || continue
      if HOME=$scratch/home CLAUDE_CONFIG_DIR=$scratch/claude claude plugin "$step" "$dir" >"$scratch/$step.log" 2>&1; then
        echo "agents-checks: claude plugin $step passed for $mod$(sed -n 's/^ *\([0-9][0-9]* pass\)$/ (\1)/p' "$scratch/$step.log")"
      else
        tail -n 40 "$scratch/$step.log" >&2
        fail "claude plugin $step failed for $mod"
      fi
    done
  done
fi

exit "$failed"
