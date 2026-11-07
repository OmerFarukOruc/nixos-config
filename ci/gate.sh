#!/usr/bin/env bash
# usage: ci/gate.sh [--evaluate-only]
# Checks the commits from origin/main to the pushed revision (PRE_COMMIT_TO_REF in the pre-push hook, else HEAD):
# ci/private-scan.sh on them unless --evaluate-only is given, and ci/agents-checks.sh on the agents/ paths they
# touch. Unless every path they touch is under agents/, it then runs ci/checks.sh, with --evaluate-only when given,
# then ci/unit-cycles.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

head=${PRE_COMMIT_TO_REF:-HEAD}
base=$(git merge-base origin/main "$head" 2>/dev/null) || base=
agents=() others=0
if [[ -n $base ]]; then
  while IFS= read -r -d '' path; do
    [[ -n $path ]] || continue
    if [[ $path == agents/* ]]; then agents+=("$path"); else others=1; fi
  done < <(git -c core.quotePath=false log --no-renames --name-only -z --format= "$base..$head")
  if [[ ${1:-} != --evaluate-only && -n $(git rev-list -1 "$base..$head") ]]; then
    ci/private-scan.sh "$base" "$head"
  fi
fi

if ((${#agents[@]})); then
  mapfile -d '' -t agents < <(printf '%s\0' "${agents[@]}" | sort -zu)
  ci/agents-checks.sh "$head" "${agents[@]}"
  if ((! others)); then
    echo "gate: every changed path is under agents/, so the Nix checks are skipped"
    exit 0
  fi
fi

ci/checks.sh "$@"
ci/unit-cycles.sh
