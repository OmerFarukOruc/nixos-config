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
  exit 0
fi

# shellcheck source=/dev/null
. scripts/lib/running-revision.sh
if runs_tree_of "$main" ||
  [[ -f $same && $(<"$same") == "$main $(readlink -f /run/current-system)" ]]; then
  echo "$host already runs main at ${main:0:12}."
  rm -f -- "$waiting"
  exit 0
fi

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
