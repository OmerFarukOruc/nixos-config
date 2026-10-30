#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

roots=
if [[ ${1:-} == --roots ]]; then
  roots=${2:?usage: ci/build-hosts.sh [--roots DIR] [HOST...]}
  shift 2
  mkdir -p "$roots"
fi
if (($# == 0)); then
  mapfile -t hosts < <(nix eval --json .#nixosConfigurations --apply builtins.attrNames | jq -r '.[]')
else
  hosts=("$@")
fi
for host in "${hosts[@]}"; do
  echo "== $host"
  link=(--no-link)
  [[ -z $roots ]] || link=(--out-link "$roots/$host")
  nix build "${link[@]}" --print-out-paths ".#nixosConfigurations.$host.config.system.build.toplevel"
done
