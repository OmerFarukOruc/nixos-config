#!/usr/bin/env bash
# usage: scripts/rehearse-moving-main.sh ROUND...
# Runs this checkout's scripts/auto-update.sh as a rehearsal on nixos-rog
# while main moves: the rehearsal reads the test branch rehearsal-moving-main
# as main, and this script pushes an empty commit to that branch when the run
# logs "Round N starts" for each N in ROUND. `1` makes the run publish in round
# 2; `1 2 3` makes it give up in round 3. It writes the run's log under
# ~/.local/state/rehearse-moving-main/ and prints its round lines.
# For the duration it points oruc-auto-update-rehearsal.service at the copied
# script with a runtime drop-in, and it removes the drop-in and the test branch
# when it ends. The run's popups reach the desktop session.
# Exits 0 when the run succeeded, 1 when it failed or could not start, 2 for a
# usage error or another host.
set -euo pipefail
cd "$(dirname "$0")/.."

usage="usage: $0 ROUND..."
if (($# == 0)); then
  echo "$usage" >&2
  exit 2
fi
for round in "$@"; do
  if [[ ! $round =~ ^[1-9][0-9]*$ ]]; then
    echo "$usage" >&2
    exit 2
  fi
done
if [[ $(</proc/sys/kernel/hostname) != nixos-rog ]]; then
  echo "The updater units run on nixos-rog only." >&2
  exit 2
fi

unit=oruc-auto-update-rehearsal.service
branch=rehearsal-moving-main
for active in oruc-auto-update.service "$unit"; do
  if systemctl is-active --quiet "$active"; then
    echo "$active is running; try again when it ends." >&2
    exit 1
  fi
done
if git ls-remote --exit-code origin "refs/heads/$branch" >/dev/null; then
  echo "origin already has $branch, maybe from a run that did not clean up. Delete it after checking that no run uses it." >&2
  exit 1
fi
bash_path=$(systemctl show -p ExecStart --value "$unit" | grep -o 'path=[^ ;]*' | head -n 1)
bash_path=${bash_path#path=}
if [[ ! -x $bash_path ]]; then
  echo "Could not read the bash path from $unit's ExecStart." >&2
  exit 1
fi

dropin_dir=/run/systemd/system/$unit.d
dropin=$dropin_dir/moving-main.conf
log_dir=${XDG_STATE_HOME:-$HOME/.local/state}/rehearse-moving-main
mkdir -p -- "$log_dir"
log=$log_dir/$(date +%Y%m%dT%H%M%S).log
copy=$(mktemp -d)
pushed=false
cleanup() {
  if systemctl is-active --quiet "$unit"; then
    sudo -n systemctl stop "$unit" || true
  fi
  sudo -n rm -f -- "$dropin" || true
  sudo -n rmdir -- "$dropin_dir" 2>/dev/null || true
  sudo -n systemctl daemon-reload || true
  if $pushed; then
    quiet_push --delete "$branch" || true
  fi
  rm -rf -- "${copy:?}"
}
trap cleanup EXIT

# quiet_push ARG...: pushes to origin. GitHub answers a push of a new branch
# with a hint to open a pull request; only a failed push shows what it printed.
quiet_push() {
  local output
  if ! output=$(git push --quiet origin "$@" 2>&1); then
    printf '%s\n' "$output" >&2
    return 1
  fi
}

# move_main ROUND: adds an empty commit on top of the test branch.
move_main() {
  local commit
  git fetch --quiet origin "$branch"
  commit=$(git -c commit.gpgsign=false commit-tree -p FETCH_HEAD \
    -m "test: move $branch at the start of round $1" 'FETCH_HEAD^{tree}')
  quiet_push "$commit:refs/heads/$branch"
  echo "Moved $branch to ${commit:0:12} at the start of round $1." | tee -a "$log"
}

# The unit runs as oruc from its own state directory, so the copy must be
# readable outside this shell's umask.
chmod 755 "$copy"
install -m 644 scripts/auto-update.sh "$copy/auto-update.sh"
git fetch --quiet origin main
pushed=true
quiet_push "origin/main:refs/heads/$branch"
printf '[Service]\nExecStart=\nExecStart=%s %s\nEnvironment=AUTO_UPDATE_REHEARSAL_MAIN=%s\n' \
  "$bash_path" "$copy/auto-update.sh" "$branch" >"$copy/moving-main.conf"
sudo -n mkdir -p -- "$dropin_dir"
sudo -n install -m 644 -- "$copy/moving-main.conf" "$dropin"
sudo -n systemctl daemon-reload

start=$(date +%s)
sudo -n systemctl start --no-block "$unit"
# --no-block returns before the unit leaves inactive.
for _ in $(seq 30); do
  [[ $(systemctl show -p ActiveState --value "$unit") == inactive ]] || break
  sleep 1
done

# Polls the journal instead of following it, so no reader outlives the run.
seen=0
while :; do
  state=$(systemctl show -p ActiveState --value "$unit")
  mapfile -t lines < <(journalctl -u "$unit" --since "@$start" -o cat --no-pager)
  for ((i = seen; i < ${#lines[@]}; i++)); do
    printf '%s\n' "${lines[i]}" >>"$log"
    if [[ ${lines[i]} =~ ^Round\ ([0-9]+)\ starts ]] && [[ " $* " == *" ${BASH_REMATCH[1]} "* ]]; then
      move_main "${BASH_REMATCH[1]}"
    fi
  done
  seen=${#lines[@]}
  [[ $state == active || $state == activating ]] || break
  sleep 5
done

result=$(systemctl show -p Result --value "$unit")
echo "Log: $log"
grep -E '^(Round [0-9]+ starts|Moved |main moved)|/pull/[0-9]+$' "$log" || true
echo "Result: $result"
[[ $result == success ]]
