CLAUDE_TOOLS_LOCK_STALE=10
declare -A _claude_lock_id=()

_claude_lock_age() {
  local mtime
  mtime=$(stat -c %Y -- "$1" 2>/dev/null) || return 1
  echo $(($(date +%s) - mtime))
}

_claude_lock_identity() {
  local id
  id=$(stat -c '%i %w' -- "$1" 2>/dev/null) || return 1
  [[ "$id" != *' -' ]] || return 1
  echo "$id"
}

_claude_lock_break() {
  local lock="$1" age
  (
    flock -w 5 9 || exit 0
    age=$(_claude_lock_age "$lock") && ((age > CLAUDE_TOOLS_LOCK_STALE)) || exit 0
    rmdir -- "$lock" 2>/dev/null
    exit 0
  ) 9>"$lock.break"
}

_claude_lock_try() {
  local lock="$1.lock" tries="$2" id age n
  for ((n = 0; n < tries; n++)); do
    if mkdir -- "$lock" 2>/dev/null; then
      if id=$(_claude_lock_identity "$lock"); then
        _claude_lock_id[$lock]="$id"
        return 0
      fi
      rmdir -- "$lock" 2>/dev/null || true
      echo "  config: not changed, cannot read a birth time of $lock on this filesystem" >&2
      return 2
    fi
    if age=$(_claude_lock_age "$lock") && ((age > CLAUDE_TOOLS_LOCK_STALE)); then
      _claude_lock_break "$lock" || true
      continue
    fi
    sleep 0.1
  done
  return 1
}

claude_config_lock() {
  local rc=0
  _claude_lock_try "$1" 100 || rc=$?
  ((rc != 1)) || echo "  config: not changed, $1.lock is held" >&2
  return $((rc ? 1 : 0))
}

claude_config_lock_all() {
  local f rc round=0 held_locks=() pauses=(0.2 0.4 0.8 1.6) blocked
  local deadline=$((${EPOCHREALTIME//[.,]/} + CLAUDE_TOOLS_LOCK_STALE * 1000000))
  while :; do
    rc=0 held_locks=()
    for f in "$@"; do
      _claude_lock_try "$f" 5 || {
        rc=$?
        blocked="$f"
        break
      }
      held_locks+=("$f")
    done
    ((rc)) || return 0
    for f in "${held_locks[@]}"; do claude_config_unlock "$f"; done
    ((rc == 1)) || return 1
    if ((${EPOCHREALTIME//[.,]/} >= deadline)); then
      echo "  config: not changed, $blocked.lock is held" >&2
      return 1
    fi
    sleep "${pauses[round < 3 ? round : 3]}"
    round=$((round + 1))
  done
}

claude_config_unlock() {
  local lock="$1.lock" id
  id="${_claude_lock_id[$lock]:-}"
  [[ -n "$id" ]] || return 0
  unset "_claude_lock_id[$lock]"
  if [[ "$(_claude_lock_identity "$lock" 2>/dev/null)" == "$id" ]]; then
    rmdir -- "$lock" 2>/dev/null || true
  fi
  return 0
}

claude_config_unlock_all() {
  local lock
  for lock in "${!_claude_lock_id[@]}"; do claude_config_unlock "${lock%.lock}"; done
  return 0
}
