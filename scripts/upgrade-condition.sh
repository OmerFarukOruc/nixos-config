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
echo "$main" >"$state/candidate"
echo "Installing main at ${main:0:12}."
