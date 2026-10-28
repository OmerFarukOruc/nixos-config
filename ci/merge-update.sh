#!/usr/bin/env bash
# usage: ci/merge-update.sh PARENT BUNDLE PATH...
# Runs in the merge jobs of .github/workflows/update.yml, the only jobs that may
# push. Pushes the one commit in BUNDLE to main when it sits on PARENT, the
# main its place job checked, and changes only the listed paths. It runs no
# code of the update or of a flake input.
set -euo pipefail

parent=${1:?usage: merge-update.sh PARENT BUNDLE PATH...}
bundle=${2:?usage: merge-update.sh PARENT BUNDLE PATH...}
shift 2
(($#)) || {
  echo "usage: merge-update.sh PARENT BUNDLE PATH..." >&2
  exit 2
}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

git fetch --quiet "$bundle" HEAD
commit=$(git rev-parse FETCH_HEAD)
[[ $(git rev-list --parents -n 1 "$commit") == "$commit $parent" ]] || {
  echo "::error::The update commit does not sit on the main that its place job checked."
  exit 1
}
excludes=()
for path in "$@"; do excludes+=(":!$path"); done
other=$(git diff --name-only "$parent" "$commit" -- . "${excludes[@]}")
[[ -z $other ]] || {
  echo "::error::The update changes files outside $*: $other"
  exit 1
}
! git diff --quiet "$parent" "$commit" || {
  echo "::error::The update commit changes nothing."
  exit 1
}
# main accepts only a fast-forward. A push that fails while main stays put,
# such as a server error, is tried again. A push whose answer got lost can have
# landed, so main is checked first.
for attempt in 1 2 3; do
  if git push --quiet origin "$commit:refs/heads/main"; then
    echo "Merged ${commit:0:12} to main." >>"$summary"
    exit 0
  fi
  # A failed fetch leaves origin/main as it was, and the next push either
  # lands or is refused as not a fast-forward.
  git fetch --quiet origin main || true
  if git merge-base --is-ancestor "$commit" origin/main; then
    echo "Merged ${commit:0:12} to main." >>"$summary"
    exit 0
  fi
  if [[ $(git rev-parse origin/main) != "$parent" ]]; then
    echo "::warning::main moved again before the push, so this update is not merged; the next run starts from it."
    exit 0
  fi
  ((attempt == 3)) || sleep 10
done
echo "::error::The push to main failed three times while main stayed at ${parent:0:12}."
exit 1
