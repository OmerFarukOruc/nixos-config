# shellcheck shell=bash
# Sourced by rotate-e2e.sh and agent-e2e.sh after they set tools and write "$dir/real-usage.json".

signed_in() {
  jq -e --arg n "$1" '.accounts[] | select(.name == $n) | .state == "ok" or .state == "expiring"' \
    "${dir:?}/real-usage.json" >/dev/null
}

idle_profile() {
  local n d p busy
  for n in $("${tools:?}" accounts names); do
    grep -qxF -- "$n" <<<"$*" && continue
    signed_in "$n" || continue
    d=$("$tools" accounts dir "$n")
    [[ -n "$d" ]] || continue
    busy=0
    for p in $(pgrep -x 'claude|\.claude-wrapped'); do
      tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | grep -qxF "CLAUDE_CONFIG_DIR=$d" && busy=1
    done
    ((busy)) || {
      echo "$n"
      return
    }
  done
}
