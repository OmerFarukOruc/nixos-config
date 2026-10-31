#!/usr/bin/env bash
set -Eeuo pipefail

repo=${DEPLOY_REPOSITORY:?}
unit_name=oruc-auto-update
host=$(</proc/sys/kernel/hostname)
dir=$STATE_DIRECTORY/repo
failed=$STATE_DIRECTORY/failed-main
failed_why=$STATE_DIRECTORY/failed-main.why
waiting=$STATE_DIRECTORY/waiting
same=$STATE_DIRECTORY/same-system
deferred_since=$STATE_DIRECTORY/deferred-since
deferred_notified=$STATE_DIRECTORY/deferred-notified
deploy_now=$STATE_DIRECTORY/deploy-now
export GIT_CONFIG_GLOBAL=/dev/null
# shellcheck source=/dev/null
. "${DEPLOY_LIB:?}"
main='' status='' outcome=''

# notify URGENCY TITLE BODY. Succeeds only when the notification was shown. The
# body can start with "- ", which notify-send would read as an option without
# the "--". During a shutdown the session bus can stop answering, and
# notify-send would then wait past the 30 s that systemd gives a stopping run
# before it kills it.
notify() {
  local bus
  bus=/run/user/$(id -u)/bus
  [[ -S $bus ]] || return 1
  DBUS_SESSION_BUS_ADDRESS=unix:path=$bus timeout 5 notify-send -a "System update" -u "$1" -- "$2" "$3"
}
warn() { echo "$*"; }

defer_for_load() {
  local available now since='' waited_day=false out rc=0 working=0
  now=$(date +%s)
  [[ ! -f $deferred_since ]] || since=$(<"$deferred_since")
  if [[ $since =~ ^[0-9]+$ ]]; then
    ((now - since < 86400)) || waited_day=true
  else
    since=''
  fi
  available=$(awk '$1 == "MemAvailable:" { print $2 }' /proc/meminfo)
  if ((available < 10485760)); then
    echo "Deferred: MemAvailable is $((available / 1024)) MiB, below the 10 GiB a build of main needs. The next run tries again."
    if [[ -z $since ]]; then
      echo "$now" >"$deferred_since"
    elif $waited_day && [[ ! -f $deferred_notified ]] &&
      notify normal "Update waiting" "$host has deferred the deploy of main since $(date -d "@$since" '+%F %H:%M'), and memory is below 10 GiB now. See: journalctl -u $unit_name"; then
      : >"$deferred_notified"
    fi
    return 0
  fi
  [[ -x ${HERDR_BIN:-} ]] || return 1
  out=$(timeout 10 "$HERDR_BIN" agent list 2>/dev/null) || rc=$?
  ((rc != 0)) || working=$(jq -e -s '[.[].result.agents[] | select(.agent_status == "working")] | length' <<<"$out" 2>/dev/null) || rc=$?
  ((rc != 0)) || [[ $working =~ ^[0-9]+$ ]] || rc=1
  if ((rc != 0)); then
    echo "Could not read herdr's agents (exit $rc); deploying as if none were working."
    return 1
  fi
  ((working > 0)) || return 1
  if $waited_day; then
    echo "Deploying although $working herdr agents are working, because the deploy has waited since $(date -d "@$since" '+%F %H:%M')."
    return 1
  fi
  echo "Deferred: $working herdr agents are working. The next run tries again; after 24 hours the deploy goes ahead."
  [[ -n $since ]] || echo "$now" >"$deferred_since"
  return 0
}
reported=false
fail() {
  reported=true
  echo "$*" >&2
  notify critical "Update failed" "$*" || true
}
on_exit() {
  local status=$?
  if ((status != 0)) && ! $reported; then
    fail "Exit $status. See: journalctl -u $unit_name"
  fi
}
trap on_exit EXIT
trap '[[ $BASHPID != "$$" ]] || fail "See: journalctl -u $unit_name"' ERR
trap 'reported=true; notify critical "Update stopped" "systemd stopped the run at its time limit or for a shutdown. See: journalctl -u $unit_name" || true; exit 143' TERM

github_config
sync_main "$repo" "$dir"

# A main whose deploy failed waits until main moves. This comes before the
# check of the running release, because after status 73 this host runs main
# while its boot entries still name the previous system.
if [[ -f $failed && $(<"$failed") == "$main" ]]; then
  if read -r failed_at failed_status failed_run 2>/dev/null <"$failed_why"; then
    error=$(journalctl "_SYSTEMD_INVOCATION_ID=$failed_run" -g '^\s*error: [A-Za-z]' -o cat |
      sed -E -n '1{s/^[[:space:]]*(error: )?//;s|/nix/store/[a-z0-9]{32}-|/nix/store/…-|g;p}') || true
    echo "The deploy of main at ${main:0:12} failed at $(date -d "@$failed_at" '+%F %H:%M') with exit $failed_status and waits for main to move.${error:+ First error: ${error:0:200}}"
  else
    echo "The deploy of main at ${main:0:12} failed before and waits for main to move."
  fi
  rm -f -- "$deploy_now"
  exit 0
fi

# shellcheck source=/dev/null
. scripts/lib/running-revision.sh
if runs_tree_of "$main" ||
  [[ -f $same && $(<"$same") == "$main $(readlink -f /run/current-system)" ]]; then
  echo "$host already runs main at ${main:0:12}."
  rm -f -- "$waiting" "$deferred_since" "$deferred_notified" "$deploy_now"
  exit 0
fi

deploy_lock=$HOME/.local/state/nixos-config-deploy/deploy.lock
if [[ -f $deploy_lock ]] && ! flock -n "$deploy_lock" true; then
  echo "Deferred: another deploy holds the deploy lock ($(cat -- "${deploy_lock%/*}/deploy.owner" 2>/dev/null || echo "owner unknown")). The next run tries again."
  rm -f -- "$deploy_now"
  exit 0
fi
if [[ -f $deploy_now ]]; then
  echo "upgrade asked for this run, so it skips the load check."
elif defer_for_load; then
  exit 0
fi
rm -f -- "$deferred_since" "$deferred_notified" "$deploy_now"

eval_log=$RUNTIME_DIRECTORY/eval.log
new_system=$(nix build --no-link --print-out-paths ".#nixosConfigurations.$host.config.system.build.toplevel" 2>"$eval_log") || new_system=
cat "$eval_log" >&2
[[ -n $new_system ]] || exit_on_download_failure "$eval_log"
if [[ $new_system == "$(readlink -f /run/current-system)" ]]; then
  echo "$main $new_system" >"$same" || true
  echo "$host already runs the system of main at ${main:0:12}."
  rm -f -- "$waiting"
  exit 0
fi

deploy_main
case $outcome in
  done)
    rm -f -- "$failed" "$failed_why" "$waiting"
    notify normal "System updated" "$host now runs main at ${main:0:12}." || true
    ;;
  wait)
    previous=
    [[ -f $waiting ]] && previous=$(<"$waiting")
    record=$status
    if ((status == 78)) && [[ $previous != 78 ]]; then
      notify normal "Update waiting" "$host runs a release with changes main lacks. Merge them into main, or deploy main with ./deploy.sh --replace $host. See: journalctl -u $unit_name" || record=
    elif ((status == 77)) && [[ $previous == 77 ]]; then
      notify normal "Update waiting" "Another deploy has held $host's deploy lock since the last run. See: journalctl -u $unit_name" || true
    fi
    if [[ -n $record ]]; then
      echo "$record" >"$waiting"
    else
      rm -f -- "$waiting"
    fi
    ;;
  retry)
    fail "deploy.sh exit $status. The next run tries again. See: journalctl -u $unit_name"
    exit 1
    ;;
  failed)
    echo "$(date +%s) $status ${INVOCATION_ID:-}" >"$failed_why"
    echo "$main" >"$failed"
    if ((status == 73)); then
      fail "$host runs main at ${main:0:12}, but its boot entries failed, so the next boot starts the previous system. See: journalctl -u $unit_name"
    else
      fail "deploy.sh exit $status. $host keeps its system until main moves. See: journalctl -u $unit_name"
    fi
    exit 1
    ;;
esac
