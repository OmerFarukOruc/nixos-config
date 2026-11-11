#!/usr/bin/env bash
# usage: ci/gate.sh [--no-private-scan]
# Checks the commits from origin/main to the pushed revision (PRE_COMMIT_TO_REF in the pre-push hook, else HEAD):
# ci/private-scan.sh on them unless --no-private-scan is given, and ci/agents-checks.sh on the agents/ paths they
# touch. Unless every path they touch is under agents/, named by no .nix file, and neither inside a skill folder nor a
# Codex agent file that only one of the two revisions holds (home-manager/modules/agent-skills lists agents/skills and
# home-manager/modules/agents.nix lists agents/codex/agents at evaluation), it then runs ci/checks.sh, then
# ci/unit-cycles.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

scan=true
case "$*" in
  '') ;;
  --no-private-scan) scan=false ;;
  *)
    echo "usage: $0 [--no-private-scan]" >&2
    exit 2
    ;;
esac

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
    listed=
    if [[ $path == agents/skills/*/* ]]; then
      listed=${path#agents/skills/}
      listed=agents/skills/${listed%%/*}
    elif [[ $path == agents/codex/agents/* ]]; then
      listed=$path
    fi
    if [[ -n $listed ]]; then
      git cat-file -e "$base:$listed" 2>/dev/null && git cat-file -e "$head:$listed" 2>/dev/null || nix=1
    fi
  done < <(git -c core.quotePath=false log --no-renames --name-only -z --format= "$base..$head")
  if $scan && [[ -n $(git rev-list -1 "$base..$head") ]]; then
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

ci/checks.sh
ci/unit-cycles.sh
