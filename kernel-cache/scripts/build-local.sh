#!/usr/bin/env bash
# Builds kernel variants on this machine in a nixos/nix container and pushes
# them to Cachix, for when the GitHub runner is too slow or times out.
# A later workflow run then finds every path in the cache and records it.
#
# usage: CACHIX_AUTH_TOKEN=... scripts/build-local.sh [--rev <sha>] [--record] <variant>...
#   --rev     nix-cachyos-kernel revision to build (default: the one in flake.lock)
#   --record  start the GitHub workflow afterwards, so it records the build
# The token is read from the environment and reaches the container through a
# 0600 env file, never a command-line argument.
set -euo pipefail

cache=omerfarukoruc
cache_key='omerfarukoruc.cachix.org-1:6OxbnSmF+Agsn0w9aya633NTlxjxXAtsETYNcImB87c='
# Provides only the cachix client; it need not match the kernel-cache lock.
nixpkgs=github:nixos/nixpkgs/3ed67ec0a4d3c7ab4ae1f04f8ee8df07bfa506a2
# Keeps the compilers and earlier builds between runs.
volume=nix-kernel-cache-store
# The kernel-cache directory, mounted into the container as /src.
repo_dir=$(cd "$(dirname "$0")/.." && pwd)

rev='' record=false variants=()
while (($#)); do
  case $1 in
    --rev)
      rev=$2
      shift 2
      ;;
    --record)
      record=true
      shift
      ;;
    -*)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 64
      ;;
    *)
      variants+=("$1")
      shift
      ;;
  esac
done
if ((${#variants[@]} == 0)); then
  printf '%s\n' 'Name at least one variant, for example zen4 or x86_64-v3.' >&2
  exit 64
fi
if [[ -n $rev && ! $rev =~ ^[0-9a-f]{40}$ ]]; then
  printf '%s\n' '--rev needs a full 40-character commit SHA.' >&2
  exit 64
fi
if [[ -z ${CACHIX_AUTH_TOKEN:-} ]]; then
  printf '%s\n' 'Set CACHIX_AUTH_TOKEN to a token that may push to the cache.' >&2
  exit 64
fi

env_file=$(mktemp)
trap 'rm -f -- "$env_file"' EXIT
chmod 600 "$env_file"
printf 'CACHIX_AUTH_TOKEN=%s\n' "$CACHIX_AUTH_TOKEN" >"$env_file"

docker run --rm -i --security-opt label=disable \
  --env-file "$env_file" \
  -e NIX_CONFIG=$'experimental-features = nix-command flakes\nsandbox = false\nmax-jobs = auto\ncores = 0\nextra-substituters = https://'"$cache"$'.cachix.org https://attic.xuyh0120.win/lantian\nextra-trusted-public-keys = '"$cache_key"' lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc=' \
  -v "$volume":/nix -v "$repo_dir":/src:ro \
  nixos/nix:latest bash -euo pipefail -s -- "$rev" "$nixpkgs" "$cache" "${variants[@]}" <<'CONTAINER'
rev=$1 nixpkgs=$2 cache=$3; shift 3
cp -r /src /work && cd /work
git config --global --add safe.directory '*'
if [[ -n $rev ]]; then
  nix flake lock --override-input nix-cachyos-kernel "github:xddxdd/nix-cachyos-kernel/$rev"
fi
printf 'Building nix-cachyos-kernel %s\n' "$(nix eval --raw --impure --expr '(builtins.fromJSON (builtins.readFile ./flake.lock)).nodes.nix-cachyos-kernel.locked.rev')"
targets=()
for variant in "$@"; do
  installables=$(nix eval --raw ".#installables.$variant")
  read -ra variant_targets <<<"$installables"
  targets+=("${variant_targets[@]}")
done
nix build --print-build-logs --no-link --print-out-paths "${targets[@]}" >/tmp/paths
nix shell "$nixpkgs#cachix" -c cachix push "$cache" </tmp/paths
printf 'In the cache now:\n'
while read -r path; do printf '  %s\n' "${path#/nix/store/}"; done </tmp/paths
CONTAINER

if [[ $record == true ]]; then
  gh workflow run kernel-cache --repo OmerFarukOruc/nixos-config ${rev:+-f rev="$rev"}
  printf '%s\n' 'Started the kernel-cache workflow; it substitutes these paths and records them.'
fi
