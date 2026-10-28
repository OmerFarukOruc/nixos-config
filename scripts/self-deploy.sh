#!/usr/bin/env bash
set -euo pipefail

repo=${DEPLOY_REPOSITORY:?}
unit_name=self-deploy
host=$(</proc/sys/kernel/hostname)
dir=$STATE_DIRECTORY/repo
failed=$STATE_DIRECTORY/failed-main
waiting=$STATE_DIRECTORY/waiting
profile=/nix/var/nix/profiles/system
export GIT_CONFIG_GLOBAL=/dev/null
# shellcheck source=/dev/null
. "${DEPLOY_LIB:?}"
main='' status='' outcome=''

warn() { printf '<4>%s\n' "$*" >&2; }
reported=false
fail() {
  reported=true
  printf '<3>%s\n' "$*" >&2
}
on_exit() {
  local status=$?
  if ((status != 0)) && ! $reported; then
    fail "The run ended with exit $status. See: journalctl -u $unit_name"
  fi
}
trap on_exit EXIT
trap 'fail "systemd stopped the run at its time limit or for a shutdown. See: journalctl -u $unit_name"; exit 143' TERM

previous=
[[ ! -f $waiting ]] || previous=$(<"$waiting")
rm -f -- "$waiting"

github_config
sync_main "$repo" "$dir"

current=$(readlink -f /run/current-system)
settled=false
[[ $(readlink -f "$profile") == "$current" ]] && settled=true

# shellcheck source=/dev/null
. scripts/lib/running-revision.sh
if $settled && runs_tree_of "$main"; then
  echo "$host already runs main at ${main:0:12}."
  rm -f -- "$failed"
  exit 0
fi

if [[ -f $failed ]] && read -r failed_main failed_at failed_status <"$failed" && [[ $failed_main == "$main" ]]; then
  if ((failed_status == 73)); then
    fail "The deploy of main at ${main:0:12} failed at $(date -u -d "@$failed_at" '+%F %H:%M UTC') with exit 73. $host runs it, but its boot entries failed, so the next boot starts the previous system. See: journalctl -u $unit_name"
  else
    fail "The deploy of main at ${main:0:12} failed at $(date -u -d "@$failed_at" '+%F %H:%M UTC') with exit $failed_status. $host keeps its system until main moves. See: journalctl -u $unit_name"
  fi
  exit 1
fi

eval_log=$RUNTIME_DIRECTORY/eval.log
new_system=$(nix eval --raw --no-write-lock-file ".#nixosConfigurations.$host.config.system.build.toplevel" 2>"$eval_log") || new_system=
cat "$eval_log" >&2
[[ -n $new_system ]] || exit_on_download_failure "$eval_log"
if $settled && [[ $new_system == "$current" ]]; then
  echo "$host already runs the system of main at ${main:0:12}."
  exit 0
fi

deploy_main
case $outcome in
  done)
    rm -f -- "$failed"
    echo "$host now runs main at ${main:0:12}."
    ;;
  wait)
    if ((status == 78)); then
      fail "$host runs a release with changes that main lacks. Merge them into main, or run ./deploy.sh --replace $host switch from a checkout of main on nixos-desktop or nixos-rog. See: journalctl -u $unit_name"
      exit 1
    fi
    echo "$status" >"$waiting"
    if [[ $previous == "$status" ]]; then
      fail "Another deploy has held up $host since the last run (status $status). See: journalctl -u $unit_name"
      exit 1
    fi
    warn "Another deploy is under way on $host (status $status). The next run tries again."
    ;;
  retry)
    fail "deploy.sh exit $status. The next run tries again. See: journalctl -u $unit_name"
    exit 1
    ;;
  failed)
    echo "$main $(date +%s) $status" >"$failed"
    if ((status == 73)); then
      fail "$host runs main at ${main:0:12}, but its boot entries failed, so the next boot starts the previous system. See: journalctl -u $unit_name"
    else
      fail "deploy.sh exit $status. $host keeps its system until main moves. See: journalctl -u $unit_name"
    fi
    exit 1
    ;;
esac
