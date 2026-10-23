#!/usr/bin/env bash
# usage: scripts/check-on-rog.sh [--fix]
# Runs ci/checks.sh, the checks of the pre-push hook, on nixos-rog, for a copy of
# this checkout (scripts/lib/rog-copy.sh), from either host.
# With --fix, it first formats the copy and locks each input that flake.lock
# lacks, copies the files that changed back here, and then checks.
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
  changed=$(rog_remote_light <<<'cd "$1" && git diff --name-only')
  if [[ -n $changed ]]; then
    printf '%s\n' "$changed" | rsync -a --files-from=- "$ROG_HOST:$ROG_COPY/" ./
    while read -r file; do echo "fixed: $file"; done <<<"$changed"
  fi
fi

rog_remote <<'EOF'
set -e
cd "$1"
git add -A
ci/checks.sh
EOF
