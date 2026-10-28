#!/usr/bin/env bash
# usage: ci/place-update.sh BASE BUNDLE OUT
# Runs in a full checkout of the current main from the place jobs of
# .github/workflows/update.yml. BUNDLE holds one update commit whose parent is
# BASE, the main its run started from, and whose tree the run checked. Writes
# that commit on top of the current main to the bundle OUT and prints the
# job's outputs: ready, parent, and recheck=true when the placed tree differs
# from the checked one, so ci/checks.sh has to run on it again.
# The update is dropped, with ready=false and a warning, only when main
# changed a file the update changes since BASE.
set -euo pipefail

base=${1:?usage: place-update.sh BASE BUNDLE OUT}
bundle=${2:?usage: place-update.sh BASE BUNDLE OUT}
out=${3:?usage: place-update.sh BASE BUNDLE OUT}

main=$(git rev-parse HEAD)
git fetch --quiet "$bundle" HEAD
update=$(git rev-parse FETCH_HEAD)
[[ $(git rev-parse "$update^") == "$base" ]] || {
  echo "::error::The update commit does not sit on the run's base ${base:0:12}." >&2
  exit 1
}
if [[ $main == "$base" ]]; then
  cp "$bundle" "$out"
  printf 'ready=true\nparent=%s\nrecheck=false\n' "$main"
  exit 0
fi
# A file that main already holds as the update has it, such as an app that the
# apps commit moved the same way, is no conflict.
mapfile -t files < <(git diff --name-only "$base" "$update")
both=
for f in "${files[@]}"; do
  git diff --quiet "$base" "$main" -- "$f" || git diff --quiet "$main" "$update" -- "$f" || both+="$f "
done
if [[ -n $both ]]; then
  echo "::warning::main changed ${both}since the run started, and this update changes them too, so it is not merged; the next run starts from that main." >&2
  echo "ready=false"
  exit 0
fi
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git cherry-pick --quiet "$update" >&2
git bundle create "$out" "HEAD^..HEAD" >&2
recheck=true
[[ $(git rev-parse 'HEAD^{tree}') == $(git rev-parse "$update^{tree}") ]] && recheck=false
echo "main moved to ${main:0:12}; the update was put on it (checked again: $recheck)." >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
printf 'ready=true\nparent=%s\nrecheck=%s\n' "$main" "$recheck"
