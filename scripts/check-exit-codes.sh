#!/usr/bin/env bash
# Fails when the exit-code table in docs/deploy.md and the codes from 64 up
# that deploy.sh and the updater set differ. treefmt passes file names, which
# this check ignores, because it always compares the whole set.
set -euo pipefail
cd "$(dirname "$0")/.."

used=$(grep -ohP '\b(exit|return) \K(6[4-9]|[7-9][0-9])\b' deploy.sh scripts/auto-update.sh | sort -u)
documented=$(sed -nE '/^## Exit codes$/,/^## /s/^\| ([0-9]+) \|.*/\1/p' docs/deploy.md | sort -u)

diff -u --label 'codes in deploy.sh and scripts/auto-update.sh' --label 'rows in docs/deploy.md' \
  <(printf '%s\n' "$used") <(printf '%s\n' "$documented") >&2
