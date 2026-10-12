#!/usr/bin/env bash
# usage: scripts/check-on-rog.sh [--fix]
# Runs the formatter check and nix flake check --no-build on nixos-rog, for a
# copy of this checkout, because fedora-desktop has no Nix. The copy holds the
# tracked files and the new files that .gitignore does not exclude, as they are
# in the working tree. With --fix, it first formats the copy and copies the
# files the formatter changed back here.
set -euo pipefail
cd "$(dirname "$0")/.."

host=nixos-rog
fix=false
case ${1:-} in
  --fix) fix=true ;;
  "") ;;
  *)
    echo "usage: $0 [--fix]" >&2
    exit 2
    ;;
esac
copy=/tmp/check-$(basename "$PWD")

# remote < SCRIPT: runs SCRIPT on the host with the copy's path as $1. The
# host's login shell is zsh, so the script runs in bash.
remote() { ssh -o BatchMode=yes "$host" bash -s -- "$copy"; }

remote <<'EOF'
rm -rf -- "$1"
EOF
git ls-files -co --exclude-standard -z | rsync -a --from0 --files-from=- ./ "$host:$copy/"
# A git flake, like CI's checkout. Without git add, Nix would leave the new
# files out of it.
remote <<'EOF'
set -e
cd "$1"
git init -q
git add -A
EOF

if [[ $fix == true ]]; then
  remote <<'EOF'
set -e
cd "$1"
nix fmt || echo "nix fmt reported problems; the check below shows them." >&2
git diff --name-only -z >"$1.changed"
EOF
  # shellcheck disable=SC2016 # the remote bash expands $1
  remote <<<'cat "$1.changed"' | rsync -a --from0 --files-from=- "$host:$copy/" ./
  # shellcheck disable=SC2016 # the remote bash expands $1
  remote <<<'tr "\0" "\n" <"$1.changed"' | sed 's/^/formatted: /'
fi

remote <<'EOF'
set -e
cd "$1"
git add -A
nix fmt -- --ci
nix flake check --no-build --no-write-lock-file
EOF
