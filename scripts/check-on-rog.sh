#!/usr/bin/env bash
# usage: scripts/check-on-rog.sh [--fix]
# Runs the formatter check and nix flake check --no-build on nixos-rog, for a
# copy of this checkout (scripts/lib/rog-copy.sh), because fedora-desktop has
# no Nix. With --fix, it first formats the copy, copies the files the
# formatter changed back here, and then checks.
set -euo pipefail
cd "$(dirname "$0")/.."

fix=false
case ${1:-} in
  --fix) fix=true ;;
  "") ;;
  *)
    echo "usage: $0 [--fix]" >&2
    exit 2
    ;;
esac

# shellcheck source=/dev/null
. scripts/lib/rog-copy.sh
rog_copy_open

if [[ $fix == true ]]; then
  rog_remote <<'EOF'
cd "$1"
nix fmt || echo "nix fmt reported problems; the check below shows them." >&2
EOF
  # shellcheck disable=SC2016 # the remote bash expands $1
  changed=$(rog_remote <<<'cd "$1" && git diff --name-only')
  if [[ -n $changed ]]; then
    printf '%s\n' "$changed" | rsync -a --files-from=- "$ROG_HOST:$ROG_COPY/" ./
    while read -r file; do echo "formatted: $file"; done <<<"$changed"
  fi
fi

# The same checks as CI's check.yml, which also forbids import from derivation.
rog_remote <<'EOF'
set -e
cd "$1"
git add -A
nix fmt -- --ci
nix flake check --no-build --no-write-lock-file --option allow-import-from-derivation false
nix eval --json --no-write-lock-file --option allow-import-from-derivation false \
  ./kernel-cache#packages.x86_64-linux --apply 'builtins.mapAttrs (_: p: p.drvPath)'
EOF
