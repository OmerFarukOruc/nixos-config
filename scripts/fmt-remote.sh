#!/usr/bin/env bash
# usage: scripts/fmt-remote.sh [FORMATTER-ARG...]
# Runs nix fmt for this checkout on nixos-rog, because fedora-desktop has no
# Nix, and copies the files it changed back. The arguments go to the
# formatter; --ci checks without writing. Exits with the formatter's status.
set -euo pipefail
cd "$(dirname "$0")/.."

host=nixos-rog
ssh_opts=(-o ConnectTimeout=15 -o BatchMode=yes)
dir=$(ssh "${ssh_opts[@]}" "$host" mktemp -d /tmp/nixos-config-fmt.XXXXXX)
trap 'ssh "${ssh_opts[@]}" "$host" rm -rf -- "$dir"' EXIT

# Tracked and untracked files, without the ones deleted in the working tree.
files=()
while IFS= read -r -d '' f; do
  [[ -e $f || -L $f ]] && files+=("$f")
done < <(git ls-files -z --cached --others --exclude-standard)
tar -cf - -- "${files[@]}" | ssh "${ssh_opts[@]}" "$host" tar -xf - -C "$dir"

# The copy needs a Git index: the flake sees only files Git knows, and
# treefmt takes its tree root from Git. stdout carries the changed files as
# a tar stream, so the formatter writes to stderr.
status=0
ssh "${ssh_opts[@]}" "$host" bash -s -- "$dir" "$@" <<'EOF' | tar -xf - || status=$?
set -uo pipefail
cd "$1" || exit 1
shift
git init -q && git add -A || exit 1
status=0
nix fmt -- "$@" >&2 || status=$?
git diff --name-only -z | tar --null -T - -cf -
exit "$status"
EOF
exit "$status"
