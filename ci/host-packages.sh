#!/usr/bin/env bash
# usage: ci/host-packages.sh build|report CACHE
# build: builds the packages of ci/cached-packages.nix, for every host, that
# neither the Cachix cache CACHE nor cache.nixos.org holds, and prints their
# output paths for cachix push. It fails when a closure holds a path that
# cache.nixos.org lacks and that is not one of those packages' outputs, because
# CACHE is public and cachix push uploads whole closures.
# report: prints a Markdown table of every output with its compressed size in
# CACHE, and their sum.
set -euo pipefail
cd "$(dirname "$0")/.."

mode=${1:-} cache=${2:-}
if [[ $mode != build && $mode != report || -z $cache ]]; then
  echo "usage: $0 build|report CACHE" >&2
  exit 2
fi

# narinfo URL PATH: prints the narinfo of store path PATH in the binary cache
# at URL, and fails when the cache lacks it.
narinfo() {
  local hash=${2#/nix/store/}
  curl -fsS --max-time 20 --retry 2 "$1/${hash%%-*}.narinfo" 2>/dev/null
}
holds() { narinfo "$@" >/dev/null; }

# One {name, drv, outs} object per package; hosts that share a build share one.
# shellcheck disable=SC2016 # a Nix expression, not shell
packages=$(nix eval --json --impure --expr 'import ./ci/cached-packages.nix (builtins.getFlake (toString ./.))' \
  --apply 'hosts: builtins.concatMap (ps: map (p: {
    inherit (p) name;
    drv = p.drvPath;
    outs = map (o: p.${o}.outPath) p.outputs;
  }) (builtins.attrValues ps)) (builtins.attrValues hosts)' | jq -c 'unique_by(.drv)')
allowed=$(jq -r '.[].outs[]' <<<"$packages")

case $mode in
  build)
    drvs=() outs=()
    while read -r package; do
      name=$(jq -r .name <<<"$package")
      missing=false
      while read -r out; do
        holds "https://$cache.cachix.org" "$out" || holds https://cache.nixos.org "$out" || missing=true
      done < <(jq -r '.outs[]' <<<"$package")
      if [[ $missing == false ]]; then
        echo "Already cached: $name" >&2
        continue
      fi
      echo "To build: $name" >&2
      drvs+=("$(jq -r '.drv' <<<"$package")^*")
      mapfile -t -O "${#outs[@]}" outs < <(jq -r '.outs[]' <<<"$package")
    done < <(jq -c '.[]' <<<"$packages")
    ((${#drvs[@]})) || exit 0

    nix build --print-build-logs --no-link "${drvs[@]}" >&2

    # A path that cache.nixos.org lacks would go to the public cache.
    # shellcheck disable=SC2016 # the inner sh expands $1, not this shell
    unexpected=$(nix path-info --recursive "${outs[@]}" | { grep -vxF -f <(echo "$allowed") || true; } |
      xargs -r -P 16 -I {} sh -c 'h=${1#/nix/store/}; curl -fsS --max-time 20 --retry 2 -o /dev/null "https://cache.nixos.org/${h%%-*}.narinfo" 2>/dev/null || echo "$1"' _ {})
    if [[ -n $unexpected ]]; then
      echo "These paths are in the closure, cache.nixos.org lacks them, and ci/cached-packages.nix does not list them:" >&2
      echo "$unexpected" >&2
      exit 1
    fi
    printf '%s\n' "${outs[@]}"
    ;;
  report)
    echo "| Output | Compressed size in $cache |"
    echo "| --- | --- |"
    total=0
    while read -r out; do
      size=$(narinfo "https://$cache.cachix.org" "$out" | sed -n 's/^FileSize: //p') || size=
      if [[ -n $size ]]; then
        total=$((total + size))
        echo "| \`${out#/nix/store/}\` | $((size / 1024)) KiB |"
      elif holds https://cache.nixos.org "$out"; then
        echo "| \`${out#/nix/store/}\` | in cache.nixos.org |"
      else
        echo "| \`${out#/nix/store/}\` | missing |"
      fi
    done <<<"$allowed"
    echo
    echo "Sum of the outputs in $cache: $((total / 1048576)) MiB."
    ;;
esac
