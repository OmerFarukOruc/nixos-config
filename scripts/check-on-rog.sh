#!/usr/bin/env bash
# usage: scripts/check-on-rog.sh [--fix]
# Runs the formatter check, the lock file check and nix flake check --no-build
# on nixos-rog, for a copy of this checkout (scripts/lib/rog-copy.sh), because
# fedora-desktop has no Nix. With --fix, it first formats the copy and locks
# each input that flake.lock lacks, copies the files that changed back here,
# and then checks.
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
# Locks each input that flake.lock lacks or whose URL changed, and drops a
# removed one; it moves no other input.
for flake in . ./kernel-cache; do
  nix flake lock "$flake" || echo "nix flake lock $flake failed; the check below shows why." >&2
done
EOF
  # shellcheck disable=SC2016 # the remote bash expands $1
  changed=$(rog_remote <<<'cd "$1" && git diff --name-only')
  if [[ -n $changed ]]; then
    printf '%s\n' "$changed" | rsync -a --files-from=- "$ROG_HOST:$ROG_COPY/" ./
    while read -r file; do echo "fixed: $file"; done <<<"$changed"
  fi
fi

# The same checks as CI's check.yml, which also forbids import from derivation.
# Evaluation warnings do not fail the check; the summary at the end lists them.
rog_remote <<'EOF'
set -eo pipefail
cd "$1"
git add -A
# With --no-write-lock-file, nix flake check passes an input that flake.lock
# lacks and only warns, and the input then follows its upstream unpinned. nix
# fmt writes the lock file, so this check runs first.
for flake in . ./kernel-cache; do
  nix flake metadata --no-update-lock-file "$flake" >/dev/null ||
    { echo "flake.lock of $flake does not match its flake.nix, as after a new or changed input; Nix's error above names the cause, and scripts/check-on-rog.sh --fix relocks" >&2; exit 1; }
done
nix fmt -- --ci
log=$(mktemp)
trap 'rm -f -- "$log"' EXIT
nix flake check --no-build --no-write-lock-file --option allow-import-from-derivation false 2>&1 | tee "$log"
nix eval --json --no-write-lock-file --option allow-import-from-derivation false \
  ./kernel-cache#packages.x86_64-linux --apply 'builtins.mapAttrs (_: p: p.drvPath)'
echo
warnings=$(grep -o 'evaluation warning: .*' "$log" | sort -u || true)
if [[ -z $warnings ]]; then
  echo "No evaluation warnings."
else
  printf '%d distinct evaluation warnings:\n%s\n' "$(wc -l <<<"$warnings")" "$warnings"
fi
EOF
