#!/usr/bin/env bash
# usage: scripts/eval-on-rog.sh [--json] [--abort-on-warn] ATTRIBUTE
# Evaluates ATTRIBUTE in a copy of this checkout on nixos-rog
# (scripts/lib/rog-copy.sh), or on nixos-desktop while nixos-rog is offline,
# and prints it. Without '#', ATTRIBUTE is a path
# under nixosConfigurations.nixos-rog.config, such as
# 'systemd.services."oruc-cpu-limits".script'; with '#' it is a flake
# attribute, such as .#nixosConfigurations.nixos-latitude.config.networking.hostName.
# A string prints raw; any other value needs --json. --abort-on-warn stops at
# the first evaluation warning and prints its stack trace.
set -euo pipefail
cd "$(dirname "$0")/.."

usage="usage: $0 [--json] [--abort-on-warn] ATTRIBUTE"
format=--raw
options=()
while [[ ${1:-} == --* ]]; do
  case $1 in
    --json) format=--json ;;
    --abort-on-warn) options=(--option abort-on-warn true --show-trace) ;;
    *)
      echo "$usage" >&2
      exit 2
      ;;
  esac
  shift
done
if (($# != 1)); then
  echo "$usage" >&2
  exit 2
fi
attr=$1
[[ $attr == *#* ]] || attr=.#nixosConfigurations.nixos-rog.config.$attr

# shellcheck source=/dev/null
. scripts/lib/rog-copy.sh
rog_copy_open
rog_remote "$format" "$attr" "${options[@]}" <<'REMOTE'
set -e
cd "$1"
nix eval "$2" --no-write-lock-file "${@:4}" "$3" </dev/null
REMOTE
