#!/usr/bin/env bash
# usage: ci/place-update.sh [--per-app] BASE BUNDLE OUT
# Runs in a full checkout of the current main from the place jobs of
# .github/workflows/update.yml. BUNDLE holds one update commit whose parent is
# BASE, the main its run started from, and whose tree the run checked. Writes
# that commit on top of the current main to the bundle OUT and prints the
# job's outputs: ready, parent, and recheck=true when the placed tree differs
# from the checked one, so ci/checks.sh has to run on it again.
# The update is dropped, with ready=false and a warning, only when main
# changed a file the update changes since BASE. With --per-app, for the apps
# commit, only the apps whose pkgs/NAME.nix or pkgs/NAME/ main changed are
# dropped, and the other apps go on.
set -euo pipefail

usage="usage: place-update.sh [--per-app] BASE BUNDLE OUT"
per_app=false
[[ ${1:-} == --per-app ]] && per_app=true && shift
base=${1:?$usage}
bundle=${2:?$usage}
out=${3:?$usage}

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
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
# conflict PATH...: main changed the paths since BASE and holds them otherwise
# than the update does. A file that main holds as the update has it, such as
# an app that the apps commit moved the same way, is no conflict.
conflict() {
  ! git diff --quiet "$base" "$main" -- "$@" && ! git diff --quiet "$main" "$update" -- "$@"
}
app_of() {
  [[ $1 =~ ^pkgs/([^/]+)(\.nix|/.*)$ ]] && printf '%s\n' "${BASH_REMATCH[1]%.nix}"
}
mapfile -t files < <(git diff --no-renames --name-only "$base" "$update")
both=()
dropped=()
if [[ $per_app == true ]]; then
  declare -A apps=()
  for f in "${files[@]}"; do
    if app=$(app_of "$f"); then
      apps[$app]=1
    elif conflict "$f"; then
      both+=("$f")
    fi
  done
  if ((${#both[@]} == 0)); then
    for app in "${!apps[@]}"; do
      conflict "pkgs/$app.nix" "pkgs/$app" && dropped+=("$app")
    done
  fi
else
  for f in "${files[@]}"; do
    conflict "$f" && both+=("$f")
  done
fi
if ((${#both[@]})); then
  echo "::warning::main changed ${both[*]} since the run started, and this update changes them too, so it is not merged; the next run starts from that main." >&2
  echo "ready=false"
  exit 0
fi
if ((${#dropped[@]})); then
  mapfile -t dropped < <(printf '%s\n' "${dropped[@]}" | sort)
  for f in "${files[@]}"; do
    app=$(app_of "$f") || app=
    printf '%s\n' "${dropped[@]}" | grep -qxF "$app" && continue
    if git cat-file -e "$update:$f" 2>/dev/null; then
      git checkout --quiet "$update" -- "$f"
    else
      git rm --quiet --ignore-unmatch -- "$f"
    fi
  done
  if git diff --cached --quiet; then
    echo "::warning::main changed the files of ${dropped[*]} since the run started, and this update moves only those apps, so it is not merged; the next run starts from that main." >&2
    echo "ready=false"
    exit 0
  fi
  echo "::warning::main changed the files of ${dropped[*]} since the run started, so those apps stay out of this update; the next run moves them from that main." >&2
  message=$(mktemp)
  git log -1 --format=%B "$update" |
    awk -v drop="${dropped[*]}" 'BEGIN { n = split(drop, d, " "); for (i = 1; i <= n; i++) skip["- " d[i] ":"] = 1 }
      !((($1 " " $2) in skip)) { print }' >"$message"
  git commit --quiet -F "$message" >&2
else
  git cherry-pick --quiet "$update" >&2
fi
git bundle create "$out" "HEAD^..HEAD" >&2
recheck=true
[[ $(git rev-parse 'HEAD^{tree}') == $(git rev-parse "$update^{tree}") ]] && recheck=false
echo "main moved to ${main:0:12}; the update was put on it (checked again: $recheck)." >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
printf 'ready=true\nparent=%s\nrecheck=%s\n' "$main" "$recheck"
