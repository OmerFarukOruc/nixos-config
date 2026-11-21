#!/usr/bin/env bash
set -euo pipefail

state=/var/lib/nixos-upgrade
repo=$state/repo.git
home=${DEPLOY_HOME:?}
deploy_state=$home/.local/state/nixos-config-deploy
now=false
if [[ -e $state/now ]]; then
  now=true
  rm -f -- "$state/now"
fi

skip() {
  echo "$*"
  exit 1
}

if systemctl is-active --quiet deploy-rollback.timer; then
  skip "A deploy's rollback timer is pending, so this run skips."
fi
if systemctl is-active --quiet deploy-activate.service deploy-boot.service; then
  skip "A deploy's activation or boot entry install still runs, so this run skips."
fi
if [[ -e $deploy_state/deploy.lock ]] && ! flock -n "$deploy_state/deploy.lock" true; then
  skip "deploy.sh holds the deploy lock, so this run skips."
fi
mountpoint -q /boot || skip "/boot is not mounted, so this run skips."
free=$(df --output=avail -k /boot | tail -n 1)
((free >= 1048576)) || skip "/boot has $((free / 1024)) MiB free, below the 1 GiB a new kernel and initrd need, so this run skips."

[[ -d $repo ]] || git clone --quiet --bare --single-branch --branch main "${REPOSITORY:?}" "$repo"
git -C "$repo" fetch --quiet origin +main:main || skip "Fetching main failed, so this run skips; the next run tries again."
main=$(git -C "$repo" rev-parse main)

# shellcheck source=/dev/null
. "${RUNNING_REVISION_LIB:?}"
read -r revision dirty action branch <<<"$(HOME=$home running_revision)" || true
if ! $now && [[ -n $revision ]]; then
  if [[ $dirty == true || $action == test ]]; then
    skip "This host runs a $action deploy of ${branch:-a branch} at ${revision:0:12}$([[ $dirty == true ]] && echo ' from a dirty tree'), so this run skips. Run upgrade to replace it with main."
  fi
  if ! git -C "$repo" merge-base --is-ancestor "$revision" main 2>/dev/null; then
    skip "This host runs ${branch:-a branch} at ${revision:0:12}, which main lacks, so this run skips. Run upgrade to replace it with main."
  fi
fi

if ! $now && [[ -f $state/failed && $(<"$state/failed") == "$main" ]]; then
  skip "Installing main at ${main:0:12} failed before, so this run skips until main moves. Run upgrade to try again."
fi
available=$(awk '$1 == "MemAvailable:" { print $2 }' /proc/meminfo)
if ! $now && ((available < 10485760)); then
  skip "MemAvailable is $((available / 1024)) MiB, below the 10 GiB an evaluation of main needs, so this run skips."
fi
in_reboot_window() {
  local now lower=${REBOOT_WINDOW_LOWER:-} upper=${REBOOT_WINDOW_UPPER:-}
  [[ -n $lower && -n $upper ]] || return 1
  now=$(date +%H:%M)
  if [[ $lower < $upper ]]; then
    [[ ! $now < $lower && $now < $upper ]]
  else
    [[ ! $now < $lower || $now < $upper ]]
  fi
}

running_work() {
  local user=${AGENTS_USER:?} home=${AGENTS_HOME:?} uid herdr pid comm shells
  uid=$(id -u "$user")
  herdr=/etc/profiles/per-user/$user/bin/herdr
  if [[ -x $herdr ]]; then
    (cd / && runuser -u "$user" -- env -i HOME="$home" XDG_RUNTIME_DIR="/run/user/$uid" "$herdr" agent list 2>/dev/null) |
      jq -r '.result.agents[]? | select(.agent_status == "working" or .agent_status == "blocked")
        | "herdr agent \(.name // .pane_id) is \(.agent_status)"'
  fi
  while read -r pid comm; do
    shells=$(pgrep -c -P "$pid" -x 'bash|zsh|sh' || true)
    ((shells == 0)) || echo "$comm pid $pid runs $shells shell commands"
  done < <(ps -u "$uid" -o pid=,comm= | awk '$2 ~ /^\.?(claude|codex|opencode)(-wrapped|2-wrap)?$/')
  systemctl --user -M "$user@" list-units --type=service --state=activating --no-legend --plain 2>/dev/null |
    awk '{print "user unit " $1 " is running"}'
  busctl --json=short call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager \
    ListInhibitors 2>/dev/null |
    jq -r '.data[0][]? | select((.[0] | split(":") | index("shutdown")) and (.[3] | startswith("block")))
      | "\(.[1]) holds a \(.[3]) shutdown lock: \(.[2])"'
}

if in_reboot_window; then
  work=$(running_work 2>/dev/null | paste -sd ';' | sed 's/;/; /g' || true)
  if [[ -n $work ]]; then
    echo "reboot-check (log only): a reboot now would cut off: $work"
  else
    echo "reboot-check (log only): nothing runs that a reboot would cut off."
  fi
fi

echo "$main" >"$state/candidate"
echo "Installing main at ${main:0:12}."
