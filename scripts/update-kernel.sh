#!/usr/bin/env bash
# Moves the nix-cachyos-kernel input in flake.lock to the revision that the
# kernel-cache workflow last built, after checking that every path it built is
# in the omerfarukoruc Cachix cache. Hosts then download the CachyOS
# kernel and the NVIDIA open module instead of compiling them.
# Runs on fedora-desktop, which has no Nix: it copies the locked revisions of
# the input and of the inputs below it from kernel-cache/flake.lock on GitHub.
set -euo pipefail

builder=OmerFarukOruc/nixos-config
cache=https://omerfarukoruc.cachix.org
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

# Both files come from one commit, so the paths belong to the locked revision.
commit=$(gh api "repos/$builder/commits/main" --jq .sha)
fetch() {
  if ! gh api "repos/$builder/contents/kernel-cache/$1?ref=$commit" --jq .content | base64 -d >"$work/$1"; then
    printf 'kernel-cache/%s could not be read from %s at %s. flake.lock is unchanged; wait for a builder run to record a build.\n' "$1" "$builder" "${commit:0:7}" >&2
    exit 1
  fi
}
fetch flake.lock
fetch cached-paths.json

locked=$(jq -r '.nodes["nix-cachyos-kernel"].locked.rev' "$work/flake.lock")
recorded=$(jq -r '.rev // empty' "$work/cached-paths.json")
if [[ $recorded != "$locked" ]]; then
  printf 'The builder recorded paths for %s but locks %s. flake.lock is unchanged; wait for its run to finish.\n' \
    "${recorded:-no revision}" "$locked" >&2
  exit 1
fi

mapfile -t paths < <(jq -r '.paths // [] | .[]' "$work/cached-paths.json")
if ((${#paths[@]} == 0)); then
  printf '%s\n' 'cached-paths.json lists no paths. flake.lock is unchanged.' >&2
  exit 1
fi
missing=0
for path in "${paths[@]}"; do
  hash=${path#/nix/store/}
  hash=${hash%%-*}
  # curl fails on a 404 and on a network error alike; both leave the lock alone.
  if ! curl -fsS --max-time 20 --retry 2 -o /dev/null "$cache/$hash.narinfo"; then
    printf 'Not in the cache, or the cache did not answer: %s\n' "$path" >&2
    missing=1
  fi
done
if ((missing)); then
  printf '%s\n' 'flake.lock is unchanged. Wait for the builder run to finish, or check its log.' >&2
  exit 1
fi

python3 - "$work/flake.lock" "$repo_dir/flake.lock" <<'PY'
import json, sys

source = json.load(open(sys.argv[1]))["nodes"]
target_path = sys.argv[2]
target = json.load(open(target_path))
nodes = target["nodes"]

# Nodes under nix-cachyos-kernel in the target, by the input path that reaches them.
pairs = {}
def walk(src, dst):
    pairs[src] = dst
    for name, ref in source[src].get("inputs", {}).items():
        # A list is a "follows" path, not a node of its own. Both locks must
        # agree on which inputs are nodes and on every follows path.
        dst_ref = nodes[dst].get("inputs", {}).get(name)
        if isinstance(ref, str) != isinstance(dst_ref, str) or (isinstance(ref, list) and ref != dst_ref):
            sys.exit(f"flake.lock differs from the builder at input {name}; update it with Nix instead.")
        if isinstance(ref, str) and ref not in pairs:
            walk(ref, dst_ref)
walk("nix-cachyos-kernel", nodes["root"]["inputs"]["nix-cachyos-kernel"])

# The copied nodes must not be shared with inputs outside the kernel input,
# and the builder must not split a node this lock shares.
inside = set(pairs.values())
if len(inside) != len(pairs):
    sys.exit("The builder locks two nodes where flake.lock has one; update flake.lock with Nix instead.")
for name, node in nodes.items():
    if name in inside:
        continue
    for input_name, ref in node.get("inputs", {}).items():
        if (name, input_name) != ("root", "nix-cachyos-kernel") and isinstance(ref, str) and ref in inside:
            sys.exit(f"Node {ref} is shared with {name}.{input_name}; update flake.lock with Nix instead.")

kernel = nodes[pairs["nix-cachyos-kernel"]]
old = kernel["locked"]["rev"]
for src, dst in pairs.items():
    nodes[dst]["locked"] = source[src]["locked"]
with open(target_path, "w") as f:
    json.dump(target, f, indent=2)
    f.write("\n")
print(f"nix-cachyos-kernel: {old[:7]} -> {kernel['locked']['rev'][:7]}")
PY

printf 'Kernel %s, every built path is in %s.\n' "$(jq -r .version "$work/cached-paths.json")" "$cache"
# auto-update.sh commits the lock itself; a person at a terminal still has to.
if [[ -t 1 ]]; then
  printf '%s\n' 'Review and commit flake.lock, then deploy.'
fi
