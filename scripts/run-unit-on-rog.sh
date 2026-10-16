#!/usr/bin/env bash
# usage: scripts/run-unit-on-rog.sh [--user] UNIT [SECONDS]
# Runs the script of the NixOS service UNIT, as this checkout defines it, on
# nixos-rog for up to SECONDS (default 40, at most 600), on a copy of this
# checkout (scripts/lib/rog-copy.sh). It runs as root with only the unit's
# environment, so a command missing from the unit's path fails here rather
# than after a deploy. The script really acts on the laptop.
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
# The whole unit runs, ExecStartPre included. A oneshot unit still running at
# the timeout fails. A name Home Manager does not define, or a unit without
# ExecStart, is refused with exit 3.
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
. scripts/lib/rog-copy.sh
rog_copy_open
if [[ $user == true ]]; then
  rog_remote "$unit" "$seconds" <<'REMOTE'
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
# The copy starts no other unit, stops with no target and runs once.
sed -E '/^(Requires|Requisite|Wants|BindsTo|PartOf|Upholds|Conflicts|OnFailure|OnSuccess)=/d; /^\[Install\]/,$d' \
  "$file" >"$dir/$name.service"
# A oneshot unit's run is its start, so TimeoutStartSec bounds it and systemd
# ignores RuntimeMaxSec with a warning.
limit=RuntimeMaxSec
grep -qx 'Type=oneshot' "$file" && limit=TimeoutStartSec
printf '[Service]\nRestart=no\n%s=%s\n' "$limit" "$seconds" >"$dir/$name.service.d/run-unit-on-rog.conf"
systemctl --user daemon-reload

echo "running $unit in the user manager of $(id -un) for up to $seconds s; it acts on this laptop" >&2
since=$(date +%s)
# start waits for a oneshot unit's end, and for any other unit's start; a
# failed unit stays loaded, so its result can be read. A unit that ended
# cleanly is unloaded at once and reads as success.
start=0
systemctl --user start "$name.service" </dev/null || start=$?
deadline=$((SECONDS + seconds + 15))
while [[ $(systemctl --user show -P ActiveState "$name.service") =~ ^(active|activating|deactivating|reloading)$ ]] &&
  ((SECONDS < deadline)); do
  sleep 1
done
journalctl --user -u "$name.service" --since "@$since" -o cat --no-pager
result=$(systemctl --user show -P Result "$name.service")
code=$(systemctl --user show -P ExecMainStatus "$name.service")
case $result in
  success)
    if ((start != 0)); then
      echo "the user manager did not start $unit (systemctl exit $start)" >&2
      exit 1
    fi
    echo "exit status: 0"
    ;;
  timeout)
    if [[ $limit == TimeoutStartSec ]]; then
      echo "failed: the oneshot unit still ran after $seconds s"
      exit 1
    fi
    echo "still running after $seconds s: a pass for a long-running unit"
    ;;
  *)
    echo "failed: $result, exit status $code"
    exit 1
    ;;
esac
REMOTE
  exit
fi
rog_remote "$unit" "$seconds" <<'REMOTE'
set -euo pipefail
cd "$1"
# One evaluation gives what the run needs: whether the unit runs as root, its
# script, its environment, and runtimeShell, which NixOS runs a unit script
# with and which is not on the unit's PATH.
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
}'
spec=$(nix eval --json --no-write-lock-file .#nixosConfigurations.nixos-rog \
  --apply "${expression/UNIT/$2}" </dev/null)
if [[ $(jq -r .asRoot <<<"$spec") != true ]]; then
  echo "refused: $2 runs as another user, and root would hide its permission failures" >&2
  exit 3
fi
if ! jq -e '.script != ""' <<<"$spec" >/dev/null; then
  echo "refused: $2 has no script option" >&2
  exit 3
fi
script=$PWD/unit-script
jq -r .script <<<"$spec" >"$script"
mapfile -t setenv < <(jq -r '.environment[] | "-E", .' <<<"$spec")
shell=$(jq -r .shell <<<"$spec")

# A transient service, so stopping it also stops the processes the script
# started, as with the real unit.
name=run-unit-on-rog-$2-$$
echo "running $2 as root for up to $3 s; it acts on this laptop" >&2
status=0
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
