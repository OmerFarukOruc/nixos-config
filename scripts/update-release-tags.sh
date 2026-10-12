#!/usr/bin/env bash
# usage: scripts/update-release-tags.sh [--except] [INPUT...]
# Moves flake inputs pinned to a GitHub release tag (github:owner/repo/v1.2.3)
# to that repository's newest release and locks them: every such input, only
# the INPUTs named, or with --except all but those.
# Prints "input: old -> new" for each input it moved. An input whose release
# lookup or lock fails stays where it is.
set -euo pipefail
cd "$(dirname "$0")/.."

# A signal between the edit and the lock leaves flake.nix as it was.
work=$(mktemp -d)
trap '[[ ! -e $work/flake.nix ]] || cp -- "$work/flake.nix" flake.nix; rm -rf -- "$work"' EXIT

except=false
if [[ ${1:-} == --except ]]; then
  except=true
  shift
fi
named=" $* "

version='^v[0-9]+(\.[0-9]+)*$'
pinned=$(jq -r --arg version "$version" '.nodes as $n | $n.root.inputs | to_entries[]
  | select(.value | type == "string") | $n[.value].original as $o
  | select($o.type == "github" and (($o.ref // "") | test($version)))
  | "\(.key) \($o.owner)/\($o.repo) \($o.ref)"' flake.lock)
[[ -n $pinned ]] || exit 0

while read -r input repo tag; do
  if (($#)); then
    [[ $named == *" $input "* ]] && listed=true || listed=false
    [[ $listed != "$except" ]] || continue
  fi
  latest=$(gh api "repos/$repo/releases/latest" --jq .tag_name) || continue
  # releases/latest can be a backport older than the pin, or an unversioned tag.
  [[ $latest =~ $version && $latest != "$tag" ]] || continue
  [[ $(printf '%s\n' "$tag" "$latest" | sort -V | tail -n 1) == "$latest" ]] || continue
  old="\"github:$repo/$tag\"" new="\"github:$repo/$latest\""
  grep -qF "$old" flake.nix || continue
  cp flake.nix "$work/flake.nix"
  sed -i "s|${old//./\\.}|$new|" flake.nix
  if nix flake update "$input"; then
    echo "$input: $tag -> $latest"
  else
    cp "$work/flake.nix" flake.nix
  fi
  rm -f "$work/flake.nix"
done <<<"$pinned"
