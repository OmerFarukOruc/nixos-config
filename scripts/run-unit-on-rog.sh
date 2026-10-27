#!/usr/bin/env bash
# usage: scripts/run-unit-on-rog.sh [--user] UNIT [SECONDS]
# Runs the script of the NixOS service UNIT, as this checkout defines it, on
# nixos-rog for up to SECONDS (default 40, at most 600), on a copy of this
# checkout there (scripts/lib/work-copy.sh), so the build runs on the laptop
# too. From another host it exits 1 at once while Tailscale reports nixos-rog
# offline. It first builds the unit file, which
# also builds the script and every package of the unit's path. It runs as root
# with only the unit's environment, so a command missing from the unit's path
# fails here rather than after a deploy. The script really acts on the laptop.
#
# A unit still running at the timeout passes, as a long-running unit should;
# a failed one makes this script exit 1. A unit that runs as another user
# (User= or DynamicUser=) is refused with exit 3, because root hides its
# permission failures, and so is a unit without a script option.
# ExecStartPre, credentials and sandboxing are not reproduced.
#
# With --user, UNIT is a Home Manager user unit of oruc. The script builds
# oruc's Home Manager files, copies the unit file under a new name into the
# user manager's runtime unit directory without its dependencies, [Install]
# section and restarts, starts it in oruc's user manager and prints its journal.
# The whole unit runs, ExecStartPre and conditions included, beside the real
# unit if that runs; %n and the unit's drop-ins differ. A oneshot unit still
# running at the timeout fails, and so does a unit whose condition was not met.
# A unit that exits is stopped before the verdict, so its ExecStop counts; the
# ExecStop of a unit still running at the timeout is not judged.
# A name Home Manager does not define, or a unit without ExecStart, is refused
# with exit 3.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  echo "usage: $0 [--user] UNIT [SECONDS]" >&2
  exit 2
}
user=false
if [[ ${1:-} == --user ]]; then
  user=true
  shift
fi
(($# == 1 || $# == 2)) || usage
unit=${1%.service}
seconds=${2:-40}
[[ $unit =~ ^[a-z0-9@_.-]+$ ]] || usage
if [[ ! $seconds =~ ^[0-9]+$ ]] || ((seconds < 1 || seconds > 600)); then
  usage
fi

# shellcheck source=/dev/null
. scripts/lib/work-copy.sh
# The unit acts on the laptop, so its copy is there.
copy_open --on-rog
if [[ $user == true ]]; then
  copy_run "$unit" "$seconds" <<'REMOTE'
set -euo pipefail
cd "$1"
unit=$2 seconds=$3
files=$(nix build --no-link --print-out-paths --no-write-lock-file \
  .#nixosConfigurations.nixos-rog.config.home-manager.users.oruc.home-files </dev/null)
file=$files/.config/systemd/user/$unit.service
if [[ ! -f $file ]]; then
  echo "refused: Home Manager defines no user unit $unit" >&2
  exit 3
fi
if ! grep -q '^ExecStart=' "$file"; then
  echo "refused: $unit has no ExecStart" >&2
  exit 3
fi

name=run-unit-on-rog-$unit-$$
dir=$XDG_RUNTIME_DIR/systemd/user
cleanup() {
  systemctl --user stop "$name.service" 2>/dev/null || true
  systemctl --user reset-failed "$name.service" 2>/dev/null || true
  rm -rf -- "${dir:?}/$name.service" "${dir:?}/$name.service.d"
  systemctl --user daemon-reload || true
}
trap cleanup EXIT
mkdir -p -- "$dir/$name.service.d"
# The copy starts and stops no other unit and runs once. Home Manager writes
# [Install] first, so only that section's lines go.
awk '
  /^\[/ { install = ($0 == "[Install]") }
  install { next }
  /^(Requires|Requisite|Wants|BindsTo|PartOf|Upholds|Conflicts|OnFailure|OnSuccess|PropagatesStopTo|StopPropagatedFrom|StopWhenUnneeded|RefuseManualStop|Sockets)=/ { next }
  { print }
' "$file" >"$dir/$name.service"
# A oneshot unit's run is its start, so TimeoutStartSec bounds it and systemd
# ignores RuntimeMaxSec with a warning. RemainAfterExit keeps a unit that ran
# and exited cleanly loaded as active (exited); one whose condition failed
# never runs, stays inactive and unloads.
limit=RuntimeMaxSec
grep -qx 'Type=oneshot' "$file" && limit=TimeoutStartSec
printf '[Service]\nRestart=no\nRemainAfterExit=yes\n%s=%s\n' "$limit" "$seconds" \
  >"$dir/$name.service.d/run-unit-on-rog.conf"
systemctl --user daemon-reload

echo "running $unit in the user manager of $(id -un) for up to $seconds s; it acts on this laptop" >&2
since=$(date +%s)
# start waits for a oneshot unit's end, and for any other unit's start.
start=0
systemctl --user start "$name.service" </dev/null || start=$?
show() { systemctl --user show -P "$1" "$name.service"; }
deadline=$((SECONDS + seconds + 15))
while [[ $(show ActiveState) =~ ^(activating|deactivating|reloading)$ ||
  ($(show ActiveState) == active && $(show SubState) != exited) ]] && ((SECONDS < deadline)); do
  sleep 1
done
state=$(show ActiveState)
# A unit that exited cleanly stays active (exited) here. Stopping it runs its
# ExecStop now, as the real unit would after ExecStart, so a failing ExecStop
# shows in the verdict.
stopped=false
if [[ $state == active && $(show SubState) == exited ]]; then
  stopped=true
  status=$(show ExecMainStatus)
  systemctl --user stop "$name.service" </dev/null || true
  state=$(show ActiveState)
  [[ $state == failed ]] || state=exited
fi
journal=$(journalctl --user -u "$name.service" --since "@$since" -o cat --no-pager)
printf '%s\n' "$journal"
result=$(show Result)
if [[ $state == exited ]]; then
  echo "exit status: $status"
elif [[ $state == active ]]; then
  echo "still running after $seconds s: a pass for a long-running unit"
elif [[ $state =~ ^(failed|deactivating)$ && $result == timeout && $limit == RuntimeMaxSec &&
  $stopped == false && $(show ActiveEnterTimestampMonotonic) != 0 ]]; then
  # RuntimeMaxSec ends a long-running unit with a timeout once it is active,
  # and a slow stop leaves it deactivating; a start that timed out never
  # made it active.
  echo "still running after $seconds s: a pass for a long-running unit"
elif [[ $state =~ ^(failed|deactivating)$ ]]; then
  echo "failed: $result, exit status $(show ExecMainStatus)"
  exit 1
elif ((start != 0)); then
  echo "the user manager did not start $unit (systemctl exit $start)" >&2
  exit 1
elif grep -q -E "unmet condition check|Skipped due to 'exec-condition'" <<<"$journal"; then
  echo "$unit did not run: a condition of the unit was not met" >&2
  exit 1
else
  echo "$unit stopped without a result to read; its journal is above" >&2
  exit 1
fi
REMOTE
  exit
fi
copy_run "$unit" "$seconds" <<'REMOTE'
set -euo pipefail
cd "$1"
# One evaluation gives what the run needs: whether the unit runs as root, its
# script, its environment, the unit file to build, and runtimeShell, which
# NixOS runs a unit script with and which is not on the unit's PATH.
expression='host: let
  service = host.config.systemd.services."UNIT";
  config = service.serviceConfig;
  environment = service.environment;
in {
  asRoot = (config.User or null) == null && !(config.DynamicUser or false);
  script = service.script;
  environment = map (n: "${n}=${toString environment.${n}}")
    (builtins.filter (n: environment.${n} != null) (builtins.attrNames environment));
  shell = host.pkgs.runtimeShell;
  unit = host.config.systemd.units."UNIT.service".unit.drvPath;
}'
spec=$(nix eval --json --no-write-lock-file .#nixosConfigurations.nixos-rog \
  --apply "${expression//UNIT/$2}" </dev/null)
if [[ $(jq -r .asRoot <<<"$spec") != true ]]; then
  echo "refused: $2 runs as another user, and root would hide its permission failures" >&2
  exit 3
fi
if ! jq -e '.script != ""' <<<"$spec" >/dev/null; then
  echo "refused: $2 has no script option" >&2
  exit 3
fi
# The evaluation builds nothing, so the packages of the unit's path may be
# missing from the store until this build.
nix build --no-link --no-write-lock-file "$(jq -r .unit <<<"$spec")^out" </dev/null
script=$PWD/unit-script
jq -r .script <<<"$spec" >"$script"
mapfile -t setenv < <(jq -r '.environment[] | "-E", .' <<<"$spec")
shell=$(jq -r .shell <<<"$spec")

# A transient service, so stopping it also stops the processes the script
# started, as with the real unit.
name=run-unit-on-rog-$2-$$
echo "running $2 as root for up to $3 s; it acts on this laptop" >&2
status=0
# The unit runs outside this script's processes, so a stopped
# run-unit-on-rog.sh, which sends TERM to them again and again (copy_stop in
# scripts/lib/work-copy.sh), stops it here, with TERM ignored so that
# systemctl finishes.
trap 'trap "" TERM; sudo -n systemctl stop "$name.service" 2>/dev/null || true; exit 143' TERM
sudo -n systemd-run --quiet --pipe --wait --unit="$name" -p RuntimeMaxSec="$3" \
  "${setenv[@]}" "$shell" -e "$script" </dev/null || status=$?
if ((status == 0)); then
  echo "exit status: 0"
  exit 0
fi
result=$(systemctl show -P Result "$name.service")
code=$(systemctl show -P ExecMainStatus "$name.service")
sudo -n systemctl reset-failed "$name.service" 2>/dev/null || true
case $result in
  timeout) echo "still running after $3 s: a pass for a long-running unit" ;;
  # A unit systemd never loaded shows as success.
  success)
    echo "systemd-run exited with $status before the unit ran" >&2
    exit 1
    ;;
  *)
    echo "failed: $result, exit status $code"
    exit 1
    ;;
esac
REMOTE
