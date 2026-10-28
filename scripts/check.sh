#!/usr/bin/env bash
# usage: scripts/check.sh [--fix]
# Runs ci/checks.sh, the checks of the pre-push hook, on this host for a copy
# of this checkout (scripts/lib/work-copy.sh), so a checkout without the devenv
# shell loaded can run them too.
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
. scripts/lib/work-copy.sh
copy_open

if [[ $fix == true ]]; then
  copy_run <<'EOF'
cd "$1"
nix fmt || echo "nix fmt reported problems; the check below shows them." >&2
for flake in . ./kernel-cache; do
  nix flake lock "$flake" || echo "nix flake lock $flake failed; the check below shows why." >&2
done
EOF
  # shellcheck disable=SC2016 # the remote bash expands $1
  changed=$(copy_run_light <<<'cd "$1" && git diff --name-only')
  if [[ -n $changed ]]; then
    printf '%s\n' "$changed" | rsync -a --files-from=- "$(copy_path)" ./
    while read -r file; do echo "fixed: $file"; done <<<"$changed"
  fi
fi

copy_run <<'EOF'
set -e
cd "$1"
git add -A
ci/checks.sh
EOF
