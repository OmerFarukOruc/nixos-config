# shellcheck shell=bash
# Sourced by scripts that rewrite a Claude Code .claude.json. Claude Code writes the file while it holds the directory
# lock <file>.lock (a mkdir lock, read from the 2.1.301 binary: stale after 10 s without an mtime change), so a rewrite
# takes the same lock and a write of a live session cannot land between the read and the move.
#
# The callers hold a lock for well under that bound, so the helper never refreshes it. A caller that holds one for more
# than 10 s can lose it to a stale break; the break is best effort between our own runs. A caller that needs several
# locks takes them with claude_config_lock_all, so none of them ages while the caller waits for another.
#
# The lock directory stays empty, as Claude Code expects, so Claude Code can break a lock one of our holders left behind
# when it died. The holder recognises its own directory by inode plus birth time, which it reads right after `mkdir`
# (the filesystem must report a birth time, or the lock fails). `lock` and `unlock` must run in the same shell, because
# the identity lives in a variable of that shell. Two directories created within one kernel clock tick can share both
# values, so a foreign lock made that fast after ours was removed is not told apart; the tick is the kernel's timestamp
# granularity, about 4 ms on this host (kernel 6.12), and finer on kernels with multigrain timestamps (6.13 and later).

CLAUDE_CONFIG_LOCK_STALE=10
# The locks this shell holds: lock path to the identity of the directory it created.
declare -A _claude_lock_id=()

_claude_lock_age() {
  local mtime
  mtime=$(stat -c %Y -- "$1" 2>/dev/null) || return 1
  echo $(($(date +%s) - mtime))
}

# _claude_lock_identity DIR: prints "inode birth-time" of DIR. Fails when the filesystem reports no birth time.
_claude_lock_identity() {
  local id
  id=$(stat -c '%i %w' -- "$1" 2>/dev/null) || return 1
  [[ "$id" != *' -' ]] || return 1
  echo "$id"
}

# _claude_lock_break LOCK: removes LOCK when it is older than 10 s. Our own runs take turns on <LOCK>.break, and the age
# is read again inside the turn, so a lock another run broke and took meanwhile is not removed. The empty .break file
# stays: removing it while another run waits on its flock lets a third run make a new file and take a second flock, and
# then two runs break at once.
_claude_lock_break() {
  local lock="$1" age
  (
    flock -w 5 9 || exit 0
    age=$(_claude_lock_age "$lock") && ((age > CLAUDE_CONFIG_LOCK_STALE)) || exit 0
    rmdir -- "$lock" 2>/dev/null
    exit 0
  ) 9>"$lock.break"
}

# _claude_lock_try FILE TRIES: takes FILE.lock, trying up to TRIES times 0.1 s apart and breaking a stale lock on the way.
# Returns 0 when it holds the lock, 1 when the lock stayed held, and 2 (with a message) when the filesystem reports no
# birth time.
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
    if age=$(_claude_lock_age "$lock") && ((age > CLAUDE_CONFIG_LOCK_STALE)); then
      _claude_lock_break "$lock" || true
      continue
    fi
    sleep 0.1
  done
  return 1
}

# claude_config_lock FILE: takes FILE.lock, waiting up to 10 s and breaking a lock nobody has touched for more than
# 10 s (a killed holder leaves one). When the lock stays held it says so on stderr and returns 1; FILE is then not to
# be changed.
claude_config_lock() {
  local rc=0
  _claude_lock_try "$1" 100 || rc=$?
  ((rc != 1)) || echo "  config: not changed, $1.lock is held" >&2
  return $((rc ? 1 : 0))
}

# claude_config_lock_all FILE...: takes the locks of all the files, in the order given, or none. A lock is awaited for
# half a second at most; when one is not free, the locks this round took are released and the round starts again after
# a growing pause, until 10 s have passed. No lock waits for the next one for long, so the first one stays far below
# the 10 s after which Claude Code may break it. On failure it says which lock was held on stderr and returns 1; the
# files are then not to be changed.
claude_config_lock_all() {
  local f rc round=0 held_locks=() pauses=(0.2 0.4 0.8 1.6) blocked
  local deadline=$((${EPOCHREALTIME//[.,]/} + CLAUDE_CONFIG_LOCK_STALE * 1000000))
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

# claude_config_unlock FILE: releases the lock claude_config_lock took, when the directory is still the one it created
# (same inode and birth time). A lock that is gone, that another process took after ours was broken, or whose identity
# cannot be read is left as it is; the call still returns 0. The check and the `rmdir` are two steps, so a lock taken in
# between is lost; the window is the time of two commands.
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

# claude_config_unlock_all: releases every lock this shell holds, for an EXIT trap.
claude_config_unlock_all() {
  local lock
  for lock in "${!_claude_lock_id[@]}"; do claude_config_unlock "${lock%.lock}"; done
  return 0
}
