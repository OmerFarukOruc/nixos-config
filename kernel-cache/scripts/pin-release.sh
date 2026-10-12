#!/usr/bin/env bash
# usage: scripts/pin-release.sh INPUT TAG
# Pins INPUT in shells/flake.nix to release TAG of its GitHub repository and
# locks it. Does nothing for a TAG that is not a version tag or not newer than
# the pin.
set -euo pipefail
cd "$(dirname "$0")/../shells"

input=$1 tag=$2
repo=$(jq -r --arg i "$input" '.nodes[$i].original | "\(.owner)/\(.repo)"' flake.lock)
current=$(jq -r --arg i "$input" '.nodes[$i].original.ref' flake.lock)
[[ $tag =~ ^v[0-9]+(\.[0-9]+)*$ && $tag != "$current" ]] || exit 0
[[ $(printf '%s\n' "$current" "$tag" | sort -V | tail -n 1) == "$tag" ]] || exit 0
sed -i "s|\"github:${repo//./\\.}/${current//./\\.}\"|\"github:$repo/$tag\"|" flake.nix
grep -qF "\"github:$repo/$tag\"" flake.nix
nix flake update "$input"
