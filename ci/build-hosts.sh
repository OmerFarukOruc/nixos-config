#!/usr/bin/env bash
# usage: ci/build-hosts.sh [HOST...]
# Builds the system of each host, or of every host without an argument, and
# prints its store path. A system that is already in the store costs only its
# evaluation.
set -euo pipefail
cd "$(dirname "$0")/.."

if (($# == 0)); then
  mapfile -t hosts < <(nix eval --json .#nixosConfigurations --apply builtins.attrNames | jq -r '.[]')
else
  hosts=("$@")
fi
for host in "${hosts[@]}"; do
  echo "== $host"
  nix build --no-link --print-out-paths ".#nixosConfigurations.$host.config.system.build.toplevel"
done
