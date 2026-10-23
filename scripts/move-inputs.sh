#!/usr/bin/env bash
# usage: scripts/move-inputs.sh [INPUT...]
# Moves flake inputs to their newest upstream and locks them: an input pinned
# to a release tag (v and digits) to its newest release, an input without a
# pin or on a branch to the head of that branch. An input pinned to a commit
# or to a tag of another form stays where it is.
# Moves every input, or only the INPUTs named.
# nix-cachyos-kernel and llm-agents never move here, because each moves only
# once a cache holds its builds: update-kernel.sh moves the kernel, and
# auto-update.sh checks cache.numtide.com before it moves llm-agents.
# Prints "input: old -> new" for each input it moved to a new release.
set -euo pipefail
cd "$(dirname "$0")/.."

named=" $* "

selected=()
while read -r input; do
  [[ $input == nix-cachyos-kernel || $input == llm-agents ]] && continue
  (($# == 0)) || [[ $named == *" $input "* ]] || continue
  selected+=("$input")
done < <(jq -r '.nodes.root.inputs | keys[]' flake.lock)
((${#selected[@]})) || exit 0

scripts/update-release-tags.sh "${selected[@]}" || echo "Some release-tagged inputs stay where they are." >&2
nix flake update "${selected[@]}"
