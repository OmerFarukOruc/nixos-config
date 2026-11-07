#!/usr/bin/env bash
# End-to-end check that sandbox-run shows each --ro and --rw path at the path the caller wrote, also when that path
# runs through a symlink. The command inside names its inputs by the same path, so a bind at the resolved path alone
# leaves the command with a missing file.
#   1. --ro of a file under a symlinked folder outside the working folder reads by the symlinked path.
#   2. --rw of a symlinked folder takes a write by the symlinked path, and the write lands in the real folder.
#   3. --ro of a symlink inside the working folder, which the sandbox binds read-only, reads through the link.
#   sandbox-run-e2e.sh [SCRIPT]    SCRIPT defaults to ../bin/sandbox-run next to this folder
# Passes when it prints PASS and exits 0. The run folder is kept on failure.
set -euo pipefail
sr="$(readlink -f "${1:-$(dirname "$0")/../bin/sandbox-run}")"
dir=$(mktemp -d /tmp/sr-e2e.XXXXXX)
ok=0
cleanup() { if ((ok)); then rm -rf "${dir:?}"; else echo "kept $dir"; fi; }
trap cleanup EXIT
fail() {
  echo "FAIL: $*"
  exit 1
}

mkdir "$dir/real" "$dir/work"
echo hello >"$dir/real/in.txt"
ln -s real "$dir/link"
ln -s ../real "$dir/work/inlink"
cd "$dir/work"

got=$("$sr" --ro "$dir/link/in.txt" -- cat "$dir/link/in.txt" 2>&1) || fail "case 1: $got"
[[ "$got" == hello ]] || fail "case 1 read '$got'"

out=$("$sr" --rw "$dir/link" -- sh -c "echo written > '$dir/link/out.txt'" 2>&1) || fail "case 2: $out"
[[ "$(cat "$dir/real/out.txt" 2>/dev/null)" == written ]] || fail "case 2: the write did not reach $dir/real/out.txt"

got=$("$sr" --ro inlink -- cat inlink/in.txt 2>&1) || fail "case 3: $got"
[[ "$got" == hello ]] || fail "case 3 read '$got'"

ok=1
echo PASS
