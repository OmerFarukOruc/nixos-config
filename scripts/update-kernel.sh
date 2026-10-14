#!/usr/bin/env bash
# usage: scripts/update-kernel.sh (no arguments)
# Moves the nix-cachyos-kernel input in flake.lock to the revision that the
# kernel-cache workflow last built, after checking that every path it built is
# in the omerfarukoruc Cachix cache. Hosts then download the CachyOS
# kernel and the NVIDIA open module instead of compiling them.
# Needs no Nix: it copies the locked revisions of the input and of the inputs
# below it from kernel-cache/flake.lock on GitHub. A person runs it on
# fedora-desktop; scripts/auto-update.sh runs it on nixos-rog.
# Exit status 1 leaves flake.lock unchanged.
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

# Compare the complete input graph before fetching paths or probing the cache.
# Prepare a candidate only; cache failures must leave the target bytes intact.
change=$(
  python3 - "$work/flake.lock" "$repo_dir/flake.lock" "$work/candidate.lock" <<'PY'
import json, sys


def refuse(message):
    sys.exit(f"{message}; update flake.lock with Nix instead.")


try:
    source_lock = json.load(open(sys.argv[1]))
    target = json.load(open(sys.argv[2]))
    source = source_lock["nodes"]
    nodes = target["nodes"]
    source_root = source_lock["root"]
    target_root = target["root"]
    if not isinstance(source, dict) or not isinstance(nodes, dict):
        refuse("Invalid lock nodes")
    source_kernel = source[source_root]["inputs"]["nix-cachyos-kernel"]
    target_kernel = nodes[target_root]["inputs"]["nix-cachyos-kernel"]
    # The cache record uses the builder's fixed node name.
    if source_kernel != "nix-cachyos-kernel":
        refuse("Unexpected builder kernel node")

    # Map by input paths, with a bijection so repeated references agree in both
    # directions, even when the locks use different node names.
    pairs = {}
    reverse = {}
    follows = []

    def resolve_follows(path, graph, root, seen=()):
        if not isinstance(path, list) or not all(isinstance(part, str) for part in path):
            refuse("Invalid follows path")
        if tuple(path) in seen:
            refuse("Cyclic follows path")
        current = root
        for name in path:
            ref = graph[current]["inputs"][name]
            if isinstance(ref, str):
                current = ref
            else:
                current = resolve_follows(ref, graph, root, seen + (tuple(path),))
            if current not in graph:
                refuse("Dangling follows path")
        return current

    def walk(src, dst):
        if not isinstance(src, str) or not isinstance(dst, str):
            refuse("Invalid kernel node reference")
        if src in pairs:
            if pairs[src] != dst:
                refuse("The builder shares a node that flake.lock splits")
            return
        if dst in reverse:
            refuse("The builder splits a node that flake.lock shares")
        src_node, dst_node = source[src], nodes[dst]
        if not isinstance(src_node, dict) or not isinstance(dst_node, dict):
            refuse("Invalid kernel node")
        if not isinstance(src_node.get("locked"), dict) or not isinstance(dst_node.get("locked"), dict):
            refuse("Invalid locked kernel metadata")
        if src_node.get("flake", True) != dst_node.get("flake", True):
            refuse("Kernel node types differ")
        src_inputs, dst_inputs = src_node.get("inputs", {}), dst_node.get("inputs", {})
        if not isinstance(src_inputs, dict) or not isinstance(dst_inputs, dict) or src_inputs.keys() != dst_inputs.keys():
            refuse("Kernel input names differ")
        pairs[src] = dst
        reverse[dst] = src
        for name, ref in src_inputs.items():
            dst_ref = dst_inputs[name]
            if isinstance(ref, str) and isinstance(dst_ref, str):
                walk(ref, dst_ref)
            elif isinstance(ref, list) and isinstance(dst_ref, list) and all(isinstance(part, str) for part in ref) and ref == dst_ref:
                follows.append(ref)
            else:
                refuse(f"Kernel input {name} differs from the builder")

    walk(source_kernel, target_kernel)
    for path in follows:
        src = resolve_follows(path, source, source_root)
        dst = resolve_follows(path, nodes, target_root)
        if src not in pairs or pairs[src] != dst:
            refuse("Kernel follows path leaves the mapped kernel graph")

    # No copied node may also belong to an input outside the kernel graph.
    inside = set(pairs.values())
    for name, node in nodes.items():
        if name in inside:
            continue
        for input_name, ref in node.get("inputs", {}).items():
            if (name, input_name) == (target_root, "nix-cachyos-kernel"):
                continue
            if isinstance(ref, list):
                ref = resolve_follows(ref, nodes, target_root)
            if isinstance(ref, str) and ref in inside:
                refuse(f"Node {ref} is shared with {name}.{input_name}")

    kernel = nodes[target_kernel]
    old = kernel["locked"]["rev"]
    new = source[source_kernel]["locked"]["rev"]
    if not isinstance(old, str) or not isinstance(new, str):
        refuse("Invalid kernel revision")
    if all(nodes[dst]["locked"] == source[src]["locked"] for src, dst in pairs.items()):
        sys.exit(0)
    for src, dst in pairs.items():
        nodes[dst]["locked"] = source[src]["locked"]
    with open(sys.argv[3], "w") as f:
        json.dump(target, f, indent=2)
        f.write("\n")
    print(f"nix-cachyos-kernel: {old[:7]} -> {new[:7]}")
except (KeyError, TypeError, ValueError, AttributeError, OSError, RecursionError) as error:
    refuse(f"Cannot compare kernel lock graphs ({type(error).__name__})")
PY
)
if [[ -z $change ]]; then
  exit 0
fi
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

cp -- "$work/candidate.lock" "$repo_dir/flake.lock"
printf '%s\n' "$change"

printf 'Kernel %s, every built path is in %s.\n' "$(jq -r .version "$work/cached-paths.json")" "$cache"
# auto-update.sh commits the lock itself; a person at a terminal still has to.
if [[ -t 1 ]]; then
  printf '%s\n' 'Review and commit flake.lock, then deploy.'
fi
