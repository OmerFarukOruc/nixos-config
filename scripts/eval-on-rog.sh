#!/usr/bin/env bash
# usage: scripts/eval-on-rog.sh [--json] ATTRIBUTE
# Evaluates ATTRIBUTE in a copy of this checkout on nixos-rog
# (scripts/lib/rog-copy.sh) and prints it. Without '#', ATTRIBUTE is a path
# under nixosConfigurations.nixos-rog.config, such as
# 'systemd.services."oruc-cpu-limits".script'; with '#' it is a flake
# attribute, such as .#nixosConfigurations.nixos-latitude.config.networking.hostName.
# A string prints raw; any other value needs --json.
set -euo pipefail
cd "$(dirname "$0")/.."

format=--raw
if [[ ${1:-} == --json ]]; then
  format=--json
  shift
fi
if (($# != 1)); then
  echo "usage: $0 [--json] ATTRIBUTE" >&2
  exit 2
fi
attr=$1
[[ $attr == *#* ]] || attr=.#nixosConfigurations.nixos-rog.config.$attr

# shellcheck source=/dev/null
. scripts/lib/rog-copy.sh
rog_copy_open
rog_remote "$format" "$attr" <<'REMOTE'
set -e
cd "$1"
nix eval "$2" --no-write-lock-file "$3" </dev/null
REMOTE
