#!/usr/bin/env bash
# Runs as root on a server from self-deploy.service. Deploys the newest main to
# this host with deploy.sh, which keeps its lock, its release records and its
# rollback (docs/deploy.md, Self-deploy of a server).
# Twin of scripts/pull-main.sh, which does the same for nixos-rog; a change to
# the clone, outage or status handling belongs in both.
# A main whose deploy failed is not deployed again until main moves, as on
# nixos-rog. After the activation, a try has restarted services and undone it,
# and a failed build fails again. After deploy.sh's status 70, 71, 74, 77 or 79
# the next run tries again, since none is main's fault. 78 waits for the running
# release's work to reach main.
# A failure leaves the unit failed and writes its line at priority err, which a
# journal shipper can alert on. A leading <N> sets the priority of a journal line.
set -euo pipefail

repo=${SELF_DEPLOY_REPOSITORY:?}
unit_name=self-deploy
host=$(</proc/sys/kernel/hostname)
dir=$STATE_DIRECTORY/repo
# "<main> <epoch> <status>" of the deploy that failed.
failed=$STATE_DIRECTORY/failed-main
# The status 70 or 77 that held the last run back.
waiting=$STATE_DIRECTORY/waiting
profile=/nix/var/nix/profiles/system
# The personal Git config of a login shell is not for this service.
export GIT_CONFIG_GLOBAL=/dev/null

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
# systemd ends the run with SIGTERM at the unit's TimeoutStartSec or when the
# system shuts down.
trap 'fail "systemd stopped the run at its time limit or for a shutdown. See: journalctl -u $unit_name"; exit 143' TERM

# A failed clone or fetch is quiet only during a network outage. Any other
# failure, such as lost repository access, would stop every deploy with no
# sign, so it fails the run.
remote_failed() {
  # Any HTTP answer, even an error status, shows that GitHub is reachable.
  if curl -sS --max-time 20 --retry 2 -o /dev/null https://github.com; then
    fail "git $1 failed while GitHub answers."
    exit 1
  fi
  warn "GitHub is unreachable; the next run tries again."
  exit 0
}

# Any run that does not end in 70 or 77 clears this, an outage included.
previous=
[[ ! -f $waiting ]] || previous=$(<"$waiting")
rm -f -- "$waiting"

if [[ ! -d $dir/.git ]]; then
  git clone --quiet "$repo" "$dir" || remote_failed clone
fi
cd "$dir"
fetched=false
for attempt in 1 2 3; do
  if git fetch --quiet origin main; then
    fetched=true
    break
  fi
  ((attempt == 3)) || sleep 10
done
$fetched || remote_failed fetch
git checkout --quiet --force --detach origin/main
git clean -fdxq
main=$(git rev-parse HEAD)

current=$(readlink -f /run/current-system)
# The boot default is the running system. After a test deploy, or after
# deploy.sh's status 73, it is not.
settled=false
[[ $(readlink -f "$profile") == "$current" ]] && settled=true

# shellcheck source=/dev/null
. scripts/lib/running-revision.sh
if $settled && runs_tree_of "$main"; then
  echo "$host already runs main at ${main:0:12}."
  rm -f -- "$failed"
  exit 0
fi

# A main whose deploy failed waits until main moves, and the run stays failed
# meanwhile, so the failure stays in view.
if [[ -f $failed ]] && read -r failed_main failed_at failed_status <"$failed" && [[ $failed_main == "$main" ]]; then
  if ((failed_status == 73)); then
    fail "The deploy of main at ${main:0:12} failed at $(date -u -d "@$failed_at" '+%F %H:%M UTC') with exit 73. $host runs it, but its boot entries failed, so the next boot starts the previous system. See: journalctl -u $unit_name"
  else
    fail "The deploy of main at ${main:0:12} failed at $(date -u -d "@$failed_at" '+%F %H:%M UTC') with exit $failed_status. $host keeps its system until main moves. See: journalctl -u $unit_name"
  fi
  exit 1
fi

# A commit that leaves this host's system as it is, such as a docs change,
# needs no deploy. When the evaluation fails, deploy.sh fails on it too and
# records this main.
new_system=$(nix eval --raw --no-write-lock-file ".#nixosConfigurations.$host.config.system.build.toplevel") || new_system=
if $settled && [[ $new_system == "$current" ]]; then
  echo "$host already runs the system of main at ${main:0:12}."
  exit 0
fi

# deploy.sh uploads a release before it finds a pending rollback timer, so
# asking first keeps a held-back run from leaving a release behind.
status=0
if systemctl is-active --quiet deploy-rollback.timer; then
  status=70
else
  echo "Deploying main at ${main:0:12} to $host."
  ./deploy.sh "$host" switch || status=$?
fi
case $status in
  0)
    rm -f -- "$failed"
    echo "$host now runs main at ${main:0:12}."
    ;;
  70 | 77)
    # 70 is the pending rollback timer of another deploy and 77 another deploy
    # holding the lock. Neither changed this host, and the next run tries again.
    # The same status twice in a row means a stuck deploy, which fails the run.
    echo "$status" >"$waiting"
    if [[ $previous == "$status" ]]; then
      fail "Another deploy has held up $host since the last run (status $status). See: journalctl -u $unit_name"
      exit 1
    fi
    warn "Another deploy is under way on $host (status $status). The next run tries again."
    ;;
  78)
    fail "$host runs a release with changes that main lacks. Merge them into main, or run ./deploy.sh --replace $host switch from a checkout of main on nixos-desktop or nixos-rog. See: journalctl -u $unit_name"
    exit 1
    ;;
  71 | 74 | 79)
    # 71 is a rollback timer that could not be armed, 74 a full ESP and 79 an
    # unmounted /boot. None is main's fault, so the next run tries again.
    fail "deploy.sh exit $status. The next run tries again. See: journalctl -u $unit_name"
    exit 1
    ;;
  *)
    # 73 is a switch whose boot entries failed. This host runs main, but the
    # next boot starts the previous system.
    echo "$main $(date +%s) $status" >"$failed"
    if ((status == 73)); then
      fail "$host runs main at ${main:0:12}, but its boot entries failed, so the next boot starts the previous system. See: journalctl -u $unit_name"
    else
      fail "deploy.sh exit $status. $host keeps its system until main moves. See: journalctl -u $unit_name"
    fi
    exit 1
    ;;
esac
