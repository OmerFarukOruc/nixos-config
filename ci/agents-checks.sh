#!/usr/bin/env bash
# usage: ci/agents-checks.sh HEAD PATH...
# Lints and parses each agents/ PATH as HEAD holds it, so uncommitted edits in the checkout do not count.
set -euo pipefail
cd "$(dirname "$0")/.."

head=${1:?usage: ci/agents-checks.sh HEAD PATH...}
shift
failed=0

fail() {
  echo "agents-checks: $*" >&2
  failed=1
}

for path in "$@"; do
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

exit "$failed"
