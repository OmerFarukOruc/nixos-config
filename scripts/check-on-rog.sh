#!/usr/bin/env bash
# usage: scripts/check-on-rog.sh [--fix]
# Runs the formatter check and nix flake check --no-build on nixos-rog, for a
# copy of this checkout, because fedora-desktop has no Nix. The copy holds the
# tracked files and the new files that .gitignore does not exclude, as they are
# in the working tree. With --fix, it first formats the copy, copies the files
# the formatter changed back here, and then checks.
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

# Each run gets its own copy, so two runs cannot remove each other's.
copy=$(ssh -o BatchMode=yes "$host" mktemp -d /tmp/check-nixos-config.XXXXXXXX)
# The trap below removes $copy, so it must be exactly the new directory.
if [[ ! $copy =~ ^/tmp/check-nixos-config\.[A-Za-z0-9]{8}$ ]]; then
  echo "mktemp on $host printed an unexpected path: $copy" >&2
  exit 1
fi
# remote < SCRIPT: runs SCRIPT on the host with the copy's path as $1. The
# host's login shell is zsh, so the script runs in bash.
remote() { ssh -o BatchMode=yes "$host" bash -s -- "$copy"; }
# shellcheck disable=SC2016 # the remote bash expands $1
trap 'remote <<<"rm -rf -- \"\$1\"" || true' EXIT

# A tracked file deleted in the working tree is listed but missing; the copy
# leaves it out, as the working tree does.
git ls-files -co --exclude-standard -z |
  rsync -a --from0 --ignore-missing-args --files-from=- ./ "$host:$copy/"
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
cd "$1"
nix fmt || echo "nix fmt reported problems; the check below shows them." >&2
EOF
  # shellcheck disable=SC2016 # the remote bash expands $1
  changed=$(remote <<<'cd "$1" && git diff --name-only')
  if [[ -n $changed ]]; then
    printf '%s\n' "$changed" | rsync -a --files-from=- "$host:$copy/" ./
    while read -r file; do echo "formatted: $file"; done <<<"$changed"
  fi
fi

# The same checks as CI's check.yml, which also forbids import from derivation.
remote <<'EOF'
set -e
cd "$1"
git add -A
nix fmt -- --ci
nix flake check --no-build --no-write-lock-file --option allow-import-from-derivation false
EOF
