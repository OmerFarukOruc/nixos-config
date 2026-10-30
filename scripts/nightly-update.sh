#!/usr/bin/env bash
set -euo pipefail

repo=${DEPLOY_REPOSITORY:?}
unit_name=nightly-update
dir=$STATE_DIRECTORY/repo
roots=$STATE_DIRECTORY/roots
logs=${RUNTIME_DIRECTORY:?}
branch=${NIGHTLY_UPDATE_BRANCH:-main}
GH_REPO=${repo#https://github.com/}
export GH_REPO=${GH_REPO%.git}
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME='nixos-config nightly update' GIT_COMMITTER_NAME='nixos-config nightly update'
export GIT_AUTHOR_EMAIL=nightly-update@devbox.invalid GIT_COMMITTER_EMAIL=nightly-update@devbox.invalid
# shellcheck source=/dev/null
. "${DEPLOY_LIB:?}"

step=start base=none pushed=none result=failed reported=false gh_ok=true
failures=()

warn() { printf '<4>%s\n' "$*" >&2; }
fail() { printf '<3>%s\n' "$*" >&2; }

record_failure() {
  failures+=("$1|$2|$3")
  fail "$1 failed with exit $2. See: journalctl -u $unit_name"
}

issue_title="Nightly update failed on $branch"

open_issue() {
  gh issue list --label nightly-update --state open --json number,title \
    --jq "[.[] | select(.title == \"$issue_title\")][0].number // empty"
}

# shellcheck disable=SC2016 # the backticks are Markdown code spans
report_body() {
  local entry name status log
  printf 'Run at %s on devbox (`journalctl -u %s`).\n\n' "$(date -u +%FT%TZ)" "$unit_name"
  printf -- '- Branch: `%s`\n- Base: `%s`\n- Pushed: `%s`\n- Result: %s\n' "$branch" "$base" "$pushed" "$result"
  if ((${#failures[@]})); then
    printf '\nFailed steps:\n\n'
    for entry in "${failures[@]}"; do
      IFS='|' read -r name status log <<<"$entry"
      printf -- '- `%s`, exit %s: `%s`\n' "$name" "$status" "$(build_error "$log" 2>/dev/null | tr '`' "'")"
    done
  fi
  if [[ -n $1 ]]; then
    printf '\nWarnings:\n\n```text\n%s\n```\n' "$1"
  fi
}

report() {
  local warnings number
  warnings=$(grep -hv '^cache.numtide.com lacks' "$logs/apps.warnings" "$logs/inputs.warnings" 2>/dev/null || true)
  if ((${#failures[@]} == 0)) && [[ -z $warnings ]]; then
    case $result in
      pushed | 'nothing to move')
        number=$(open_issue) || gh_ok=false
        [[ -z $number ]] || gh issue close "$number" --comment "The run at $(date -u +%FT%TZ) ended with: $result." >/dev/null || gh_ok=false
        ;;
    esac
    return 0
  fi
  gh label create nightly-update --color d93f0b --description "The nightly update on devbox needs attention" --force >/dev/null || gh_ok=false
  number=$(open_issue) || gh_ok=false
  if [[ -n $number ]]; then
    report_body "$warnings" | gh issue comment "$number" --body-file - >/dev/null || gh_ok=false
  else
    report_body "$warnings" | gh issue create --title "$issue_title" --label nightly-update --body-file - >/dev/null || gh_ok=false
  fi
}

on_exit() {
  local status=$?
  $reported && return
  reported=true
  ((status == 0)) || failures+=("$step|$status|$logs/$step.log")
  set +e
  report
  $gh_ok || fail "Reporting the run to GitHub failed. See: journalctl -u $unit_name"
  if ((${#failures[@]})) || ! $gh_ok; then
    exit 1
  fi
  exit 0
}
trap on_exit EXIT
trap 'fail "systemd stopped the run at its time limit or for a shutdown. See: journalctl -u $unit_name"; exit 143' TERM

now=$(date -u +%s)
reboot=$(date -u -d 'today 02:10' +%s)
((reboot > now)) || reboot=$(date -u -d 'tomorrow 02:10' +%s)
if ((reboot - now < 4 * 3600 + 40 * 60)); then
  result=skip
  echo "Too close to the 02:10 UTC reboot; the next run tries again."
  exit 0
fi

github_config
sync_main "$repo" "$dir"
if [[ $branch != main ]]; then
  git fetch --quiet origin "$branch" || remote_failed fetch
  git checkout --quiet --force --detach FETCH_HEAD
fi
base=$(git rev-parse HEAD)
# shellcheck source=/dev/null
. scripts/lib/build-error.sh
echo "Updating $branch from ${base:0:12}."

gate() {
  echo "Checking and building every host ($1)."
  {
    ci/checks.sh &&
      NIX_CONFIG="${NIX_CONFIG:-}"$'\n''allow-import-from-derivation = false' ci/unit-cycles.sh &&
      ci/build-hosts.sh --roots "$roots"
  } 2>&1 | tee "$logs/$1.log"
}

commit_move() {
  local mode=$1 subject=$2 changes=$logs/$1.changes others
  shift 2
  scripts/prepare-update.sh "$mode" nixos-rog "$changes" "$logs/$mode.warnings" 2>&1 | tee "$logs/$mode.log" || return
  if [[ ! -s $changes ]]; then
    echo "No $mode moved."
    return 0
  fi
  nix fmt --no-update-lock-file 2>&1 | tee -a "$logs/$mode.log" || return
  git add -u -- "$@" || return
  others=$(git status --porcelain --untracked-files=no | grep -v '^[MADR]  ' || true)
  if [[ -n $others ]]; then
    printf 'error: moving the %s changed files outside %s:\n%s\n' "$mode" "$*" "$others" | tee -a "$logs/$mode.log" >&2
    return 1
  fi
  {
    printf '%s\n\n' "$subject"
    cat "$changes"
  } | git commit --quiet -F -
}

move() {
  local mode=$1 before status
  before=$(git rev-parse HEAD)
  step=$mode
  echo "Moving the $mode."
  if commit_move "$@"; then
    :
  else
    status=$?
    record_failure "$mode" "$status" "$logs/$mode.log"
    git reset --quiet --hard "$before"
    git clean -fdxq
    return 0
  fi
  [[ $(git rev-parse HEAD) != "$before" ]] || return 0
  step=$mode-gate
  if gate "$step"; then
    return 0
  else
    status=$?
  fi
  record_failure "$step" "$status" "$logs/$step.log"
  git reset --quiet --hard "$before"
}

move apps 'chore(pkgs): update apps to their newest releases' pkgs
move inputs 'chore(flake): update inputs to their newest releases' flake.nix flake.lock devenv.lock pkgs

step=push
if [[ $(git rev-parse HEAD) == "$base" ]]; then
  result='nothing to move'
  echo "Nothing to push."
  exit 0
fi

git fetch --quiet origin "$branch" || remote_failed fetch
remote=$(git rev-parse FETCH_HEAD)
if [[ $remote != "$base" ]]; then
  if ! git rebase --quiet "$remote"; then
    git rebase --abort
    result=retry
    warn "$branch moved and conflicts with the update; the next run tries again."
    exit 0
  fi
  step=rebased
  if gate rebased; then
    :
  else
    record_failure rebased "$?" "$logs/rebased.log"
    exit 0
  fi
  step=push
fi

if git -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
  push --quiet origin "HEAD:refs/heads/$branch" 2>"$logs/push.log"; then
  pushed=$(git rev-parse HEAD)
  result=pushed
  echo "Pushed $branch at ${pushed:0:12}."
  exit 0
fi
cat "$logs/push.log" >&2
git fetch --quiet origin "$branch" || remote_failed fetch
if [[ $(git rev-parse FETCH_HEAD) != "$remote" ]]; then
  result=retry
  warn "$branch moved during the push; the next run tries again."
  exit 0
fi
record_failure push 1 "$logs/push.log"
