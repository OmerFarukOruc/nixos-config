#!/usr/bin/env bash
set -euo pipefail

state=/var/lib/nixos-upgrade
repo=$state/repo.git
home=${DEPLOY_HOME:?}
deploy_state=$home/.local/state/nixos-config-deploy
rm -f -- "$state/candidate"
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
if ! $now && cause=$(install_skip_cause "$repo" main "$revision" "$dirty" "$action" "$branch"); then
  skip "This host runs $cause, so this run skips. Run upgrade to replace it with main."
fi

if ! $now && [[ -f $state/failed && $(<"$state/failed") == "$main" ]]; then
  skip "Installing main at ${main:0:12} is marked as failed, so this run skips until main moves. Run upgrade to try again."
fi
available=$(awk '$1 == "MemAvailable:" { print $2 }' /proc/meminfo)
if ! $now && ((available < 10485760)); then
  skip "MemAvailable is $((available / 1024)) MiB, below the 10 GiB an evaluation of main needs, so this run skips."
fi
in_reboot_window() {
  local clock lower=${REBOOT_WINDOW_LOWER:-} upper=${REBOOT_WINDOW_UPPER:-}
  [[ -n $lower && -n $upper ]] || return 1
  clock=$(date +%H:%M)
  if [[ $lower < $upper ]]; then
    [[ ! $clock < $lower && $clock < $upper ]]
  else
    [[ ! $clock < $lower || $clock < $upper ]]
  fi
}

running_work() {
  local user=${AGENTS_USER:?} home=${AGENTS_HOME:?} uid herdr out pid comm shells
  if ! uid=$(id -u "$user" 2>/dev/null); then
    echo "unchecked: every probe, because user $user does not exist"
    return
  fi
  herdr=/etc/profiles/per-user/$user/bin/herdr
  if [[ ! -x $herdr ]]; then
    echo "unchecked: herdr agents, because $herdr is missing"
  elif out=$(cd / && timeout 10 runuser -u "$user" -- env -i HOME="$home" XDG_RUNTIME_DIR="/run/user/$uid" \
    "$herdr" agent list 2>&1); then
    jq -r '.result.agents[] | select(.agent_status == "working" or .agent_status == "blocked")
      | "herdr agent \(.name // .pane_id) is \(.agent_status)"' <<<"$out" 2>/dev/null ||
      echo "unchecked: herdr agents, because herdr agent list printed no agent list"
  elif [[ $out != *server_not_running* ]]; then
    echo "unchecked: herdr agents, because herdr agent list failed: $(head -c 120 <<<"$out")"
  fi
  while read -r pid comm; do
    shells=$(pgrep -c -P "$pid" -x 'bash|zsh|sh' || true)
    ((shells == 0)) || echo "$comm pid $pid runs $shells shell commands"
  done < <(ps -u "$uid" -o pid=,comm= | awk '$2 ~ /^\.?(claude|codex|opencode)(-wrapped|2-wrap)?$/')
  if out=$(timeout 10 systemctl --user -M "$user@" list-units --type=service --state=activating --no-legend \
    --plain 2>/dev/null); then
    awk 'NF {print "user unit " $1 " is running"}' <<<"$out"
  else
    echo "unchecked: user units, because the user manager of $user did not answer"
  fi
  if out=$(timeout 10 busctl --json=short call org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager ListInhibitors 2>/dev/null); then
    jq -r '.data[0][] | select((.[0] | split(":") | index("shutdown")) and (.[3] | startswith("block")))
      | "\(.[1]) holds a \(.[3]) shutdown lock: \(.[2])"' <<<"$out" 2>/dev/null ||
      echo "unchecked: shutdown locks, because ListInhibitors printed no list"
  else
    echo "unchecked: shutdown locks, because logind did not answer"
  fi
}

joined() {
  paste -sd ';' | sed 's/;/; /g'
}

if in_reboot_window; then
  found=$(running_work 2>/dev/null || true)
  work=$(grep -v '^unchecked: ' <<<"$found" | grep . | joined || true)
  unchecked=$(grep '^unchecked: ' <<<"$found" | sed 's/^unchecked: //' | joined || true)
  if [[ -n $work ]]; then
    line="a reboot now would cut off: $work."
  else
    line="nothing that the probes see runs that a reboot would cut off."
  fi
  echo "reboot-check (log only): $line${unchecked:+ Not checked: $unchecked.}"
fi

echo "$main" >"$state/candidate"
echo "Installing main at ${main:0:12}."
