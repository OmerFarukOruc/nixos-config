#!/usr/bin/env bash
# usage: ci/gate.sh [--evaluate-only]
# Checks the commits from origin/main to the pushed revision (PRE_COMMIT_TO_REF in the pre-push hook, else HEAD):
# ci/private-scan.sh on them unless --evaluate-only is given, and ci/agents-checks.sh on the agents/ paths they
# touch. Unless every path they touch is under agents/, named by no .nix file, and not inside a skill folder that
# only one of the two revisions holds (home-manager/modules/agent-skills lists agents/skills at evaluation), it then
# runs ci/checks.sh, with --evaluate-only when given, then ci/unit-cycles.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

head=${PRE_COMMIT_TO_REF:-HEAD}
base=$(git merge-base origin/main "$head" 2>/dev/null) || base=
agents=() nix=0
if [[ -n $base ]]; then
  while IFS= read -r -d '' path; do
    [[ -n $path ]] || continue
    if [[ $path != agents/* ]]; then
      nix=1
      continue
    fi
    agents+=("$path")
    if git grep -qF -e "$path" "$head" -- '*.nix'; then nix=1; fi
    if [[ $path == agents/skills/*/* ]]; then
      skill=${path#agents/skills/}
      skill=agents/skills/${skill%%/*}
      git cat-file -e "$base:$skill" 2>/dev/null && git cat-file -e "$head:$skill" 2>/dev/null || nix=1
    fi
  done < <(git -c core.quotePath=false log --no-renames --name-only -z --format= "$base..$head")
  if [[ ${1:-} != --evaluate-only && -n $(git rev-list -1 "$base..$head") ]]; then
    ci/private-scan.sh "$base" "$head"
  fi
fi

if ((${#agents[@]})); then
  mapfile -d '' -t agents < <(printf '%s\0' "${agents[@]}" | sort -zu)
  ci/agents-checks.sh "$head" "${agents[@]}"
  if ((! nix)); then
    echo "gate: every changed path is under agents/ and no .nix file reads it, so the Nix checks are skipped"
    exit 0
  fi
fi

ci/checks.sh "$@"
ci/unit-cycles.sh
