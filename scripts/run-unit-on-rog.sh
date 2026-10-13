#!/usr/bin/env bash
# usage: scripts/run-unit-on-rog.sh UNIT [SECONDS]
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
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  echo "usage: $0 UNIT [SECONDS]" >&2
  exit 2
}
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
