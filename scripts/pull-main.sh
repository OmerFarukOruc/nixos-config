#!/usr/bin/env bash
# Runs on nixos-rog from oruc-auto-update.service. Deploys the newest main to
# this host with deploy.sh. .github/workflows/update.yml moves the inputs and
# apps, builds every host and runs the checks before it merges an update to
# main, so this script only deploys.
# A main whose deploy failed is not deployed again until main moves. After
# deploy.sh's status 70, 71, 74, 77 or 79 the next run tries again, since none
# is main's fault. 78 waits for the running release's work to reach main.
# -E lets the ERR trap below fire inside functions too.
set -Eeuo pipefail

repo=OmerFarukOruc/nixos-config
unit_name=oruc-auto-update
host=$(</proc/sys/kernel/hostname)
dir=$STATE_DIRECTORY/repo
failed=$STATE_DIRECTORY/failed-main
# "<epoch> <status> <invocation id>" of the run that recorded $failed, so a run
# that skips that main can say why.
failed_why=$STATE_DIRECTORY/failed-main.why
# The deploy.sh exit status that held the last run back.
waiting=$STATE_DIRECTORY/waiting
# "<commit> <system>" when main at that commit builds the system this host
# runs, such as after a docs change. The next run on that commit and system
# then skips the evaluation, which made such a run take 58 s and 6.9 GiB
# instead of about 10 s (journal, 2026-10-23).
same=$STATE_DIRECTORY/same-system
# The personal Git config pushes over SSH and signs with an agent key; the
# service has neither.
export GIT_CONFIG_GLOBAL=/dev/null

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
# fail TITLE BODY: the critical popup of a failed run. on_exit sends a generic
# one for a failed exit that sent none, such as an unset variable under set -u,
# which skips the ERR trap.
reported=false
fail() {
  reported=true
  notify critical "$1" "$2" || true
}
on_exit() {
  local status=$?
  if ((status != 0)) && ! $reported; then
    notify critical "Update failed" "Exit $status. See: journalctl -u $unit_name" || true
  fi
}
trap on_exit EXIT
# A failure inside $(...) runs this trap in the subshell and again in the main
# shell, so only the main shell reports.
trap '[[ $BASHPID != "$$" ]] || fail "Update failed" "See: journalctl -u $unit_name"' ERR
# systemd ends the run with SIGTERM at the unit's TimeoutStartSec or when the
# system shuts down, and SIGTERM skips the ERR trap.
trap 'fail "Update stopped" "systemd stopped the run at its time limit or for a shutdown. See: journalctl -u $unit_name"; exit 143' TERM

# Nix fetches the flake inputs through GitHub's API, whose limit for a client
# without a token is too low for an evaluation. deploy.sh asks gh which pull
# request merged a running release, and the service cannot reach the login
# keyring that oruc's own gh uses. Shell builtins keep the token out of argv,
# and exported variables carry paths only.
umask 077
unset token
[[ $RUNTIME_DIRECTORY == /* ]]
token=$(<"$CREDENTIALS_DIRECTORY/github-token")
[[ $token =~ ^[a-zA-Z0-9_]+$ ]]
printf 'access-tokens = github.com=%s\n' "$token" >"$RUNTIME_DIRECTORY/nix.conf"
mkdir -p "$RUNTIME_DIRECTORY/gh"
printf 'github.com:\n    oauth_token: %s\n    git_protocol: https\n' "$token" >"$RUNTIME_DIRECTORY/gh/hosts.yml"
unset token
chmod 600 "$RUNTIME_DIRECTORY/nix.conf" "$RUNTIME_DIRECTORY/gh/hosts.yml"
export NIX_CONFIG="include $RUNTIME_DIRECTORY/nix.conf"
export GH_CONFIG_DIR="$RUNTIME_DIRECTORY/gh"

# A failed clone or fetch is quiet only during a network outage. Any other
# failure, such as lost repository access, would stop every deploy with no
# sign, so it notifies and fails.
remote_failed() {
  # Any HTTP answer, even an error status, shows that GitHub is reachable.
  if curl -sS --max-time 20 --retry 2 -o /dev/null https://github.com; then
    echo "git $1 failed while GitHub answers." >&2
    fail "Update failed" "git $1 failed while GitHub is reachable. See: journalctl -u $unit_name"
    exit 1
  fi
  echo "GitHub is unreachable; the next run tries again."
  exit 0
}

if [[ ! -d $dir/.git ]]; then
  git clone --quiet "https://github.com/$repo.git" "$dir" || remote_failed clone
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

# A commit that leaves this host's system as it is, such as a docs change,
# needs no deploy. A failed build goes on to deploy.sh, whose failure records
# this main.
if new_system=$(nix build --no-link --print-out-paths ".#nixosConfigurations.$host.config.system.build.toplevel") &&
  [[ $new_system == "$(readlink -f /run/current-system)" ]]; then
  # Only a skip of the next evaluation depends on it.
  echo "$main $new_system" >"$same" || true
  echo "$host already runs the system of main at ${main:0:12}."
  rm -f -- "$waiting"
  exit 0
fi

# deploy.sh uploads a release before it finds a pending rollback timer, so
# asking first keeps a held-back run from leaving a release behind.
status=0
if systemctl is-active --quiet deploy-rollback.timer; then
  echo "A rollback timer from another deploy is pending."
  status=70
else
  echo "Deploying main at ${main:0:12} to $host."
  ./deploy.sh "$host" switch || status=$?
fi
case $status in
  0)
    rm -f -- "$failed" "$failed_why" "$waiting"
    notify normal "System updated" "$host now runs main at ${main:0:12}." || true
    ;;
  70 | 77 | 78)
    # 70 is the pending rollback timer of another deploy, 77 another deploy
    # holding the lock and 78 a running release whose files main lacks. None
    # changed this host. 78 notifies on the first run it holds back, 77 from
    # the second run in a row, because a deploy that holds the lock 2 hours
    # later is stuck. A 78 notification that was not delivered leaves no
    # record, so the next run sends it again.
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
  71 | 74 | 79)
    # 71 is a rollback timer that could not be armed, 74 a full ESP and 79 an
    # unmounted /boot. None is main's fault, so the next run tries again.
    fail "Update failed" "deploy.sh exit $status. The next run tries again. See: journalctl -u $unit_name"
    exit 1
    ;;
  *)
    # 73 is a switch whose boot entries failed: this host runs main, but the
    # next boot starts the previous system.
    echo "$(date +%s) $status ${INVOCATION_ID:-}" >"$failed_why"
    echo "$main" >"$failed"
    if ((status == 73)); then
      fail "Update failed" "$host runs main at ${main:0:12}, but its boot entries failed, so the next boot starts the previous system. See: journalctl -u $unit_name"
    else
      fail "Update failed" "deploy.sh exit $status. $host keeps its system until main moves. See: journalctl -u $unit_name"
    fi
    exit 1
    ;;
esac
