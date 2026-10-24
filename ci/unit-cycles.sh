#!/usr/bin/env bash
# usage: ci/unit-cycles.sh
# For every host, builds its /etc/systemd/system through ci/unit-cycles.nix and
# fails when systemd-analyze finds an ordering cycle in what default.target
# pulls in. deploy.sh runs the same check on the built system (exit 80).
# Separate evaluators release the heap between hosts.
set -euo pipefail
cd "$(dirname "$0")/.."

# check_host HOST: prints the host's result and fails when its units do not
# build, hold an ordering cycle or could not be checked.
check_host() {
  local host=$1 paths units systemd rc=0 analysis
  # One evaluation of the host builds both attributes.
  paths=$(nix build --no-link --print-out-paths --impure \
    --expr "import ./ci/unit-cycles.nix (builtins.getFlake (toString ./.)) \"$host\"" units systemd) ||
    {
      echo "$host: the units do not build; Nix's error is above."
      return 1
    }
  units=$(grep -- '-system-units$' <<<"$paths")
  systemd=$(grep -v -- '-system-units$' <<<"$paths")
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

hosts=$(nix eval --json --no-write-lock-file .#nixosConfigurations --apply builtins.attrNames | jq -r '.[]')
status=0
# Wait outside check_host so errexit stays active inside the host check.
for host in $hosts; do
  check_host "$host" &
  wait "$!" || status=1
done
exit "$status"
