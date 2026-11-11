#!/usr/bin/env bash
# usage: install-report failed|installed
# Keeps one GitHub issue per host for a failed install of main, posted as the GitHub App nixos-config-hosts:
# `failed` opens it, or comments on the open one, with what an agent needs to fix the failure, and leaves the file
# `reported`; `installed` closes the issue with a comment while that file exists, then removes it. A GitHub failure
# prints one line and exits 0, and `reported` stays so the next install closes the issue. Reads HOST, SSH_LOGIN,
# REBOOTS, APP_ID_FILE, KEY_FILE and VALUES_FILE from the environment, and MONITOR_INVOCATION_ID from systemd's
# OnFailure= run.
set -euo pipefail

mode=${1:-}
case $mode in
  failed | installed) ;;
  *)
    echo "usage: install-report failed|installed" >&2
    exit 2
    ;;
esac
state=/var/lib/nixos-upgrade
reported=$state/reported
repo=OmerFarukOruc/nixos-config
host=${HOST:?}
labels=(--label install-failed --label "host:$host")
step='' what='' drv='' details=''

revision_of() {
  sed -n 's/^revision=//p' "$state/installed" 2>/dev/null || true
}

open_issue() {
  gh issue list -R "$repo" --state open "${labels[@]}" --json number --jq '.[0].number // empty'
}

private_filter() {
  local patterns
  patterns=$(sed 's/\r//; s/^[[:space:]]*//; s/[[:space:]]*$//' "${VALUES_FILE:-/dev/null}" 2>/dev/null | grep -v '^$' || true)
  if [[ -n $patterns ]]; then
    grep -v -F -e "$patterns" || true
  else
    cat >/dev/null
    echo "(left out: $host has no private-values list to filter this text with, and the repository is public)"
  fi
}

public_text() {
  local text
  text=$(private_filter)
  if gitleaks stdin --no-banner --log-level error >/dev/null 2>&1 <<<"$text"; then
    printf '%s\n' "$text"
  else
    echo "(left out: gitleaks found a possible secret in this text; read it on $host)"
  fi
}

classify() {
  local log build_log
  log=$(journalctl -u nixos-upgrade "_SYSTEMD_INVOCATION_ID=${MONITOR_INVOCATION_ID:-}" -o cat --no-pager 2>/dev/null || true)
  drv=$(grep -o -m 1 -E "error: (builder for|Cannot build) '/nix/store/[^']*\.drv'" <<<"$log" | grep -o "/nix/store/[^']*" || true)
  [[ -z $drv || $(private_filter <<<"$drv") == "$drv" ]] || drv=''
  if [[ -n $drv ]]; then
    step=build
    what="build of $(basename "$drv" .drv | cut -d- -f2-)"
    build_log=$(nix log "$drv" 2>/dev/null | tail -n 40 || true)
    [[ -n $build_log ]] || build_log=$(tail -n 40 <<<"$log")
    details=$(public_text <<<"$build_log")
  elif grep -q 'switching to system configuration' <<<"$log"; then
    step=switch
    what=switch
    details=$(systemctl --failed --no-legend --plain | awk '{print $1}' | public_text)
  else
    step=build
    what="evaluation or build"
    details=$(tail -n 40 <<<"$log" | public_text)
  fi
}

commits_since() {
  local good=$1 candidate=$2
  if [[ -n $good ]] && git -C "$state/repo.git" cat-file -e "$good^{commit}" 2>/dev/null; then
    git -C "$state/repo.git" log -n 30 --format='%n%h %s' --name-only "$good..$candidate" | sed '/^$/d'
  else
    echo "(unknown: $host has no record of its last installed revision)"
  fi
}

reproduce() {
  local candidate=$1
  if [[ $step == switch ]]; then
    echo "Read the failed units on $host: \`ssh $SSH_LOGIN\`, then \`journalctl -u nixos-upgrade -b\` and \`systemctl --failed\`."
  else
    echo "Reproduce the build on the host you work on, never over SSH: in a worktree at $candidate, run \`scripts/build.sh\` on the failed package's attribute, such as \`.#nixosConfigurations.$host.pkgs.<name>\`, and on \`.#nixosConfigurations.$host.config.system.build.toplevel\` only when the package has no attribute of its own."
  fi
}

proof() {
  echo "After the fix lands, run \`upgrade\` on $host (\`ssh $SSH_LOGIN upgrade\`); \`cat $state/installed\` then shows the new revision."
  if [[ ${REBOOTS:-false} == true ]]; then
    echo "   A fix that changes the kernel, the initrd or the kernel modules installs at $host's night reboot, so \`installed\` and this issue change at the first hourly run after it."
  fi
}

failure_body() {
  local candidate=$1 good=$2 heading='Log (last 40 lines)'
  [[ $step != switch ]] || heading='Units that failed after the switch'
  cat <<EOF
## What failed
$host could not install \`main\` at $candidate ($(date -u '+%F %H:%M UTC')). It keeps running ${good:-its current system}, the last revision it installed, and tries again when \`main\` moves.

| Host | $host |
| --- | --- |
| Failed step | $step |
| Failed package | ${drv:-none named} |
| Last good revision | ${good:-unknown} |
| Failed revision | $candidate |

## $heading
\`\`\`
$details
\`\`\`

## Commits since the last good install
\`\`\`
$(commits_since "$good" "$candidate")
\`\`\`

## For the agent fixing this
1. Read \`AGENTS.md\`. $(reproduce "$candidate")
2. Fix the cause in a worktree and land it on \`main\` the way \`AGENTS.md\` says.
3. $(proof)

Done when $host installs a revision with the fix; this issue then closes itself.
EOF
}

post_failed() {
  local candidate good body number
  candidate=$(<"$state/candidate") || return 1
  good=$(revision_of)
  classify
  body=$(failure_body "$candidate" "$good") || return 1
  number=$(open_issue) || return 1
  if [[ -n $number ]]; then
    gh issue comment "$number" -R "$repo" --body "$body" >/dev/null || return 1
    echo "install-report: commented on issue $number"
  else
    gh label create install-failed -R "$repo" --color B60205 --description "A host could not install main" --force >/dev/null || return 1
    gh label create "host:$host" -R "$repo" --color 5319E7 --description "Reported by $host" --force >/dev/null || return 1
    gh issue create -R "$repo" --title "$host: hourly install fails at ${candidate:0:12} ($what)" "${labels[@]}" --body "$body" || return 1
  fi
  touch "$reported"
}

post_installed() {
  local number revision
  number=$(open_issue) || return 1
  if [[ -n $number ]]; then
    revision=$(revision_of)
    gh issue close "$number" -R "$repo" --comment "Installed \`${revision:-main}\` at $(date -u '+%F %H:%M UTC')." >/dev/null || return 1
    echo "install-report: closed issue $number"
  fi
  rm -f "$reported"
}

if [[ $mode == installed && ! -e $reported ]]; then
  exit 0
fi
if [[ ! -r ${APP_ID_FILE:-} || ! -r ${KEY_FILE:-} ]]; then
  echo "install-report: $host has no key of the GitHub App nixos-config-hosts, so no issue is posted"
  exit 0
fi
if ! GH_TOKEN=$(gh-token generate --app-id "$(<"$APP_ID_FILE")" --key "$KEY_FILE" --token-only); then
  echo "install-report: the GitHub App token could not be made, so no issue is posted"
  exit 0
fi
export GH_TOKEN
if [[ $mode == failed ]]; then
  post_failed || echo "install-report: posting the failure to GitHub failed; the journal of nixos-upgrade holds the log"
else
  post_installed || echo "install-report: closing the issue on GitHub failed"
fi
