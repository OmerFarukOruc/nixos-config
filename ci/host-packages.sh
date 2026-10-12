#!/usr/bin/env bash
# usage: ci/host-packages.sh build|report CACHE OUTPUTS
# build: builds the packages of ci/cached-packages.nix, for every host, that
# neither the Cachix cache CACHE nor cache.nixos.org holds, and prints their
# output paths for cachix push. A package whose closure holds a path that
# cache.nixos.org lacks and that is not one of those packages' outputs is not
# printed, because CACHE is public and cachix push uploads whole closures. Each
# package is built and checked on its own; the script fails at the end when one
# of them failed, after printing the others. It writes every listed output to
# the file OUTPUTS first.
# report: prints a Markdown table of every output in the file OUTPUTS with its
# compressed size in CACHE, and their sum. It evaluates nothing, so it can run
# while the push token is on the runner.
set -euo pipefail
cd "$(dirname "$0")/.."

mode=${1:-} cache=${2:-} outputs=${3:-}
if [[ $mode != build && $mode != report || -z $cache || -z $outputs ]]; then
  echo "usage: $0 build|report CACHE OUTPUTS" >&2
  exit 2
fi

# narinfo URL PATH: prints the narinfo of store path PATH in the binary cache
# at URL, and fails when the cache lacks it.
narinfo() {
  local hash=${2#/nix/store/}
  curl -fsS --max-time 20 --retry 2 "$1/${hash%%-*}.narinfo" 2>/dev/null
}
holds() { narinfo "$@" >/dev/null; }

case $mode in
  build)
    # One {name, drv, outs} object per package; hosts that share a build share one.
    # shellcheck disable=SC2016 # a Nix expression, not shell
    packages=$(nix eval --json --impure --expr 'import ./ci/cached-packages.nix (builtins.getFlake (toString ./.))' \
      --apply 'hosts: builtins.concatMap (ps: map (p: {
        inherit (p) name;
        drv = p.drvPath;
        outs = map (o: p.${o}.outPath) p.outputs;
      }) (builtins.attrValues ps)) (builtins.attrValues hosts)' | jq -c 'unique_by(.drv)')
    allowed=$(jq -r '.[].outs[]' <<<"$packages")
    echo "$allowed" >"$outputs"

    failed=()
    while read -r package; do
      name=$(jq -r .name <<<"$package")
      mapfile -t outs < <(jq -r '.outs[]' <<<"$package")
      missing=false
      for out in "${outs[@]}"; do
        holds "https://$cache.cachix.org" "$out" || holds https://cache.nixos.org "$out" || missing=true
      done
      if [[ $missing == false ]]; then
        echo "Already cached: $name" >&2
        continue
      fi
      echo "Building $name" >&2
      if ! nix build --print-build-logs --no-link "$(jq -r '.drv' <<<"$package")^*" >&2; then
        failed+=("$name")
        continue
      fi
      # A path that cache.nixos.org lacks would go to the public cache.
      # shellcheck disable=SC2016 # the inner sh expands $1, not this shell
      unexpected=$(nix path-info --recursive "${outs[@]}" | { grep -vxF -f <(echo "$allowed") || true; } |
        xargs -r -P 16 -I {} sh -c 'h=${1#/nix/store/}; curl -fsS --max-time 20 --retry 2 -o /dev/null "https://cache.nixos.org/${h%%-*}.narinfo" 2>/dev/null || echo "$1"' _ {})
      if [[ -n $unexpected ]]; then
        echo "$name stays out of the cache. Its closure holds paths that cache.nixos.org lacks and ci/cached-packages.nix does not list:" >&2
        echo "$unexpected" >&2
        failed+=("$name")
        continue
      fi
      printf '%s\n' "${outs[@]}"
    done < <(jq -c '.[]' <<<"$packages")
    if ((${#failed[@]})); then
      echo "Not pushed: ${failed[*]}" >&2
      exit 1
    fi
    ;;
  report)
    if [[ ! -s $outputs ]]; then
      echo "The build step listed no outputs."
      exit 0
    fi
    echo "| Output | Compressed size in $cache |"
    echo "| --- | --- |"
    total=0
    while read -r out; do
      [[ -n $out ]] || continue
      size=$(narinfo "https://$cache.cachix.org" "$out" | sed -n 's/^FileSize: //p') || size=
      if [[ -n $size ]]; then
        total=$((total + size))
        echo "| \`${out#/nix/store/}\` | $((size / 1024)) KiB |"
      elif holds https://cache.nixos.org "$out"; then
        echo "| \`${out#/nix/store/}\` | in cache.nixos.org |"
      else
        echo "| \`${out#/nix/store/}\` | missing |"
      fi
    done <"$outputs"
    echo
    echo "Sum of the outputs in $cache: $((total / 1048576)) MiB."
    ;;
esac
