#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
. scripts/lib/parallel-each.sh
# shellcheck source=/dev/null
. scripts/lib/host-systems.sh

check_host() {
  local host=$1 paths units systemd rc=0 analysis
  paths=$(nix build --no-link --print-out-paths --impure --option allow-import-from-derivation false \
    --expr "import ./ci/unit-cycles.nix (builtins.getFlake (toString ./.)) \"$host\"" units systemd) ||
    {
      echo "$host: the units do not build."
      return 1
    }
  units=$(grep -- '-system-units$' <<<"$paths") || {
    echo "$host: the build printed no unit folder."
    return 1
  }
  systemd=$(grep -v -- '-system-units$' <<<"$paths") || {
    echo "$host: the build printed no systemd package."
    return 1
  }
  # systemd-analyze exits 0 also when it finds a cycle, so only its message
  # counts; any other status means it did not check.
  # --man=no: a unit's man page lookup fails where man is not on PATH.
  analysis=$(SYSTEMD_UNIT_PATH=$units "$systemd/bin/systemd-analyze" verify --man=no default.target 2>&1) || rc=$?
  if ((rc != 0)); then
    printf '%s\n' "$analysis" "$host: systemd-analyze could not check the units (exit $rc)."
    return 1
  elif grep -q 'Found ordering cycle' <<<"$analysis"; then
    echo "$host: the units hold an ordering cycle, so the next boot would not finish."
    grep -E 'ordering cycle|Job .* deleted' <<<"$analysis" || true
    return 1
  fi
  echo "$host: no ordering cycle"
}

fetch_inputs . --no-write-lock-file
names=$(host_names .)
mapfile -t hosts <<<"$names"
parallel_each check_host "${hosts[@]}"
