#!/usr/bin/env bash
# usage: scripts/rehearse-moving-main.sh ROUND...
# Runs this checkout's scripts/auto-update.sh as a rehearsal on nixos-rog
# while main moves: the rehearsal reads the test branch rehearsal-moving-main
# as main, and this script pushes an empty commit to that branch when the run
# logs "Round N starts" for each N in ROUND. `1` makes the run publish in round
# 2; `1 2 3` makes it give up in round 3. It writes the run's log under
# ~/.local/state/rehearse-moving-main/ and prints the round lines as they come.
# For the duration it points oruc-auto-update-rehearsal.service at the copied
# script with a runtime drop-in, and it removes the drop-in and the test branch
# when it ends. The run's popups reach the desktop session.
# Exits 0 when the run ended with exit 0, every ROUND started and was moved,
# the run noticed each move, and it then published in the next round, or gave
# up in round 3 when that was the last ROUND. Exits 2 for a usage error or
# another host, and non-zero for any other failure.
set -euo pipefail
cd "$(dirname "$0")/.."

usage="usage: $0 ROUND..."
if (($# == 0)); then
  echo "$usage" >&2
  exit 2
fi
declare -A wanted=()
for round in "$@"; do
  if [[ ! $round =~ ^[1-9][0-9]*$ ]]; then
    echo "$usage" >&2
    exit 2
  fi
  wanted[$round]=1
done
if [[ $(</proc/sys/kernel/hostname) != nixos-rog ]]; then
  echo "The updater units run on nixos-rog only." >&2
  exit 2
fi

unit=oruc-auto-update-rehearsal.service
branch=rehearsal-moving-main
dropin_dir=/run/systemd/system/$unit.d
dropin=$dropin_dir/moving-main.conf

# A oneshot unit is "activating" while it runs, which is-active does not count.
for other in oruc-auto-update.service "$unit"; do
  case $(systemctl show -p ActiveState --value "$other") in
    inactive | failed) ;;
    *)
      echo "$other is running; try again when it ends." >&2
      exit 1
      ;;
  esac
done
if [[ -e $dropin ]]; then
  echo "$dropin exists, maybe from a run that did not clean up. Remove it and run systemctl daemon-reload." >&2
  exit 1
fi
remote=0
git ls-remote --exit-code origin "refs/heads/$branch" >/dev/null || remote=$?
case $remote in
  2) ;;
  0)
    echo "origin already has $branch, maybe from a run that did not clean up. Delete it after checking that no run uses it." >&2
    exit 1
    ;;
  *)
    echo "git ls-remote failed (exit $remote)." >&2
    exit 1
    ;;
esac
bash_path=$(systemctl show -p ExecStart --value "$unit" | grep -o 'path=[^ ;]*' | head -n 1 || true)
bash_path=${bash_path#path=}
if [[ ! -x $bash_path ]]; then
  echo "Could not read the bash path from $unit's ExecStart." >&2
  exit 1
fi

log_dir=${XDG_STATE_HOME:-$HOME/.local/state}/rehearse-moving-main
mkdir -p -- "$log_dir"
log=$log_dir/$(date +%Y%m%dT%H%M%S).log
copy=$(mktemp -d)
pushed=false

# quiet_push ARG...: pushes to origin. GitHub answers a push of a new branch
# with a hint to open a pull request; only a failed push shows what it printed.
quiet_push() {
  local output
  if ! output=$(git push --quiet origin "$@" 2>&1); then
    printf '%s\n' "$output" >&2
    return 1
  fi
}

# shellcheck disable=SC2329 # the EXIT trap below runs it
cleanup() {
  # A second interrupt must not skip the removals below.
  trap '' INT TERM HUP
  case $(systemctl show -p ActiveState --value "$unit") in
    inactive | failed) ;;
    *) sudo -n systemctl stop "$unit" || true ;;
  esac
  sudo -n rm -f -- "$dropin" || true
  sudo -n rmdir -- "$dropin_dir" 2>/dev/null || true
  sudo -n systemctl daemon-reload || true
  if $pushed && ! quiet_push --delete "$branch"; then
    echo "Could not delete $branch on origin; delete it by hand." >&2
  fi
  rm -rf -- "${copy:?}"
}
trap cleanup EXIT

# move_main ROUND: adds an empty commit on top of the test branch.
move_main() {
  local commit
  git fetch --quiet origin "$branch"
  commit=$(git -c commit.gpgsign=false commit-tree -p FETCH_HEAD \
    -m "test: move $branch at the start of round $1" 'FETCH_HEAD^{tree}')
  quiet_push "$commit:refs/heads/$branch"
  echo "Moved $branch to ${commit:0:12} at the start of round $1."
}

install -m 644 scripts/auto-update.sh "$copy/auto-update.sh"
git fetch --quiet origin main
quiet_push "origin/main:refs/heads/$branch"
pushed=true
printf '[Service]\nExecStart=\nExecStart=%s %s\nEnvironment=AUTO_UPDATE_REHEARSAL_MAIN=%s\n' \
  "$bash_path" "$copy/auto-update.sh" "$branch" >"$copy/moving-main.conf"
sudo -n mkdir -p -- "$dropin_dir"
sudo -n install -m 644 -- "$copy/moving-main.conf" "$dropin"
sudo -n systemctl daemon-reload
# A failed state from an earlier run would otherwise read as this run's end.
sudo -n systemctl reset-failed "$unit" 2>/dev/null || true

before=$(systemctl show -p InvocationID --value "$unit")
start=$(date +%s)
sudo -n systemctl start --no-block "$unit"
# The start job is skipped on battery (ConditionACPower), which leaves the
# invocation as it was.
for _ in $(seq 30); do
  [[ $(systemctl show -p InvocationID --value "$unit") == "$before" ]] || break
  sleep 1
done
if [[ $(systemctl show -p InvocationID --value "$unit") == "$before" ]]; then
  echo "$unit did not start within 30 s; it runs only on AC power." >&2
  exit 1
fi
echo "Log: $log"

# Polls the journal instead of following it, so no reader outlives the run.
declare -A moved=()
seen=0
while :; do
  state=$(systemctl show -p ActiveState --value "$unit")
  mapfile -t lines < <(journalctl -u "$unit" --since "@$start" -o cat --no-pager)
  for ((i = seen; i < ${#lines[@]}; i++)); do
    line=${lines[i]}
    printf '%s\n' "$line" >>"$log"
    if [[ $line =~ ^(Round\ [0-9]+\ starts|main\ moved)|/pull/[0-9]+$ ]]; then
      echo "$line"
    fi
    if [[ $line =~ ^Round\ ([0-9]+)\ starts ]]; then
      round=${BASH_REMATCH[1]}
      if [[ -n ${wanted[$round]:-} && -z ${moved[$round]:-} ]]; then
        moved[$round]=1
        move_main "$round" | tee -a "$log"
      fi
    fi
  done
  ((${#lines[@]} <= seen)) || seen=${#lines[@]}
  case $state in
    inactive | failed) break ;;
  esac
  sleep 5
done

result=$(systemctl show -p Result --value "$unit")
echo "Result: $result"
status=0
[[ $result == success ]] || status=1
for round in "${!wanted[@]}"; do
  if [[ -z ${moved[$round]:-} ]]; then
    echo "Round $round never started, so main did not move there." >&2
    status=1
  fi
done
noticed=$(grep -c '^main moved' "$log" || true)
if ((noticed != ${#moved[@]})); then
  echo "main moved ${#moved[@]} times, but the run noticed $noticed." >&2
  status=1
fi
# After the last named round the run publishes in the next round, or gives up
# when that round was the last one auto-update.sh allows (max_rounds, 3).
last=$(printf '%s\n' "${!wanted[@]}" | sort -n | tail -n 1)
if ((last < 3)); then
  if ! grep -q "^Round $((last + 1)) starts" "$log" || ! grep -qE '/pull/[0-9]+$' "$log"; then
    echo "The run did not publish in round $((last + 1))." >&2
    status=1
  fi
elif ! grep -q "in round 3, and the bounds allow no further round" "$log"; then
  echo "The run did not give up in round 3." >&2
  status=1
fi
exit "$status"
