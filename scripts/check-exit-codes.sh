#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

used=$(grep -ohP '\b(exit|return) \K(6[4-9]|[7-9][0-9])\b' deploy.sh | sort -u)
documented=$(sed -nE '/^## Exit codes$/,/^## /s/^\| ([0-9]+) \|.*/\1/p' docs/deploy.md | sort -u)

diff -u --label 'codes in deploy.sh' --label 'rows in docs/deploy.md' \
  <(printf '%s\n' "$used") <(printf '%s\n' "$documented") >&2
