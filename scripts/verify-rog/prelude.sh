# Part of the remote script in scripts/verify-nixos-rog.sh.
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2086,SC2154,SC2155
set -uo pipefail
report() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; } # report NAME STATUS DETAIL
check() {                                          # check NAME DETAIL CONDITION...
  local name=$1 detail=$2
  shift 2
  if "$@" >/dev/null 2>&1; then
    report "$name" pass "$detail"
  else
    report "$name" fail "$detail"
  fi
}
armoury=/sys/class/firmware-attributes/asus-armoury/attributes
nvidia_dev=$(find_nvidia)
reapply_failed=${XDG_STATE_HOME:-$HOME/.local/state}/oruc/reapply-failed
check theme-reapply "no failed theme --reapply" test ! -e "$reapply_failed"
