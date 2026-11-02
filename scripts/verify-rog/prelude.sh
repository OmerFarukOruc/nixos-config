# shellcheck shell=bash
# shellcheck disable=SC2034,SC2086,SC2154,SC2155
set -uo pipefail
report() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
check() {
  local name=$1 detail=$2 error
  shift 2
  if error=$("$@" 2>&1 >/dev/null); then
    report "$name" pass "$detail"
  else
    error=$(head -n 1 <<<"$error" | tr '\t' ' ')
    report "$name" fail "$detail: ${error:-the check command failed}"
  fi
}
armoury=/sys/class/firmware-attributes/asus-armoury/attributes
nvidia_dev=$(find_nvidia)
reapply_failed=${XDG_STATE_HOME:-$HOME/.local/state}/oruc/reapply-failed
check theme-reapply "no failed theme --reapply" test ! -e "$reapply_failed"
check theme-root-apply "no failed oruc-theme-root --apply" test ! -e /var/lib/oruc/theme/apply-failed
