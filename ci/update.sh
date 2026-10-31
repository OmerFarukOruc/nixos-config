#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

logs=$(mktemp -d)
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
base=$(git rev-parse HEAD)
failed=()
warned=false

gate() {
  ci/checks.sh && NIX_CONFIG="${NIX_CONFIG:-}"$'\n''allow-import-from-derivation = false' ci/unit-cycles.sh
}

drop() {
  failed+=("$1")
  echo "::error::$1 failed; nothing of it is pushed."
  echo "$1 failed; nothing of it is pushed." >>"$summary"
  git reset --quiet --hard "$2"
  git clean -fdq
}

report_warnings() {
  local line
  while IFS= read -r line; do
    echo "::warning::$line"
    echo "- $line" >>"$summary"
    [[ $line == *'cache.numtide.com lacks'* ]] || warned=true
  done <"$1"
}

commit() {
  local subject=$1 changes=$2 others
  shift 2
  nix fmt --no-update-lock-file && git add -u -- "$@" || return
  others=$(git status --porcelain --untracked-files=no | grep -v '^[MADR]  ' || true)
  if [[ -n $others ]]; then
    printf 'The move changed files outside %s:\n%s\n' "$*" "$others" >&2
    return 1
  fi
  printf '%s\n\n' "$subject" | cat - "$changes" | git commit --quiet -F -
}

move() {
  local mode=$1 subject=$2 before changes=$logs/$1.changes
  shift 2
  before=$(git rev-parse HEAD)
  echo "::group::Move the $mode"
  if ! scripts/prepare-update.sh "$mode" nixos-rog "$changes" "$logs/$mode.warnings"; then
    echo "::endgroup::"
    drop "$mode" "$before"
    return 0
  fi
  report_warnings "$logs/$mode.warnings"
  if [[ ! -s $changes ]]; then
    echo "No $mode moved."
    echo "::endgroup::"
    return 0
  fi
  if ! commit "$subject" "$changes" "$@"; then
    echo "::endgroup::"
    drop "$mode" "$before"
    return 0
  fi
  echo "::endgroup::"
  echo "::group::Check the $mode"
  if ! gate; then
    echo "::endgroup::"
    drop "$mode-checks" "$before"
    return 0
  fi
  echo "::endgroup::"
  {
    echo "Moved $mode:"
    cat "$changes"
  } >>"$summary"
}

move apps 'chore(pkgs): update apps to their newest releases' pkgs
move inputs 'chore(flake): update inputs to their newest releases' flake.nix flake.lock devenv.lock pkgs

if [[ $(git rev-parse HEAD) == "$base" ]]; then
  echo "Nothing to push." | tee -a "$summary"
elif git push --quiet origin HEAD:main; then
  git log -1 --format='Pushed %H.' | tee -a "$summary"
else
  git fetch --quiet origin main
  if [[ $(git rev-parse origin/main) == "$base" ]]; then
    echo "::error::The push failed while main stayed at $base."
    exit 1
  fi
  echo "main moved during the run; the next run tries again." | tee -a "$summary"
fi
if $warned; then
  echo "::error::A move stayed out; the warnings above name the cause."
fi
((${#failed[@]} == 0)) && ! $warned
