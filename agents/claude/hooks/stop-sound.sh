#!/usr/bin/env bash
# Stop and Notification hook: soft cue if Ghostty is the focused window; louder cue otherwise.
# Notification (Claude needs input or a permission answer) uses its own pair of sounds.
# When Ghostty is not focused, a desktop notification also appears; clicking it opens the tab.
#
# Focus rules (app-level; another Ghostty tab also counts as focused):
#   1. Active window is Ghostty                        -> focused sound
#   2. Active window is another app                    -> unfocused sound
#   3. Active window unknown and Ghostty running       -> focused sound
#   4. Active window unknown and Ghostty not running   -> unfocused sound
#   5. Session runs over SSH                           -> unfocused sound
#
# Silent Stops: inside a subagent (agent_id set); while subagents or workflows are still in
# flight, because the session wakes again when they finish; and at the end of a turn the session
# started itself because a background task finished.
#
# Dedup: debounce per session_id and event.

set -u

HOOKS_DIR="${HOME}/.claude/hooks"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/claude-hooks/stop-sound"
DEBOUNCE_SECS="${CLAUDE_STOP_SOUND_DEBOUNCE_SECS:-10}"

# Claude Code passes session_id only in the stdin JSON; hooks get no CLAUDE_SESSION_ID env var.
# Reading all of stdin also keeps Claude Code from blocking on a full pipe.
input=$(cat 2>/dev/null || true)
field() { jq -r "$1" <<<"$input" 2>/dev/null || true; }

sid=$(field '.session_id // empty')
event=$(field '.hook_event_name // "Stop"')

if [[ "$event" == "Notification" ]]; then
  FOCUSED_SOUND="${CLAUDE_NOTIFY_FOCUSED_SOUND:-${HOOKS_DIR}/sounds/needs-input-soft.ogg}"
  UNFOCUSED_SOUND="${CLAUDE_NOTIFY_UNFOCUSED_SOUND:-${HOOKS_DIR}/sounds/needs-input-chime.ogg}"
else
  [[ -z "$(field '.agent_id // empty')" ]] || exit 0
  in_flight=$(field '[.background_tasks[]? | select(.type == "subagent" or .type == "workflow")] | length')
  [[ "${in_flight:-0}" == "0" ]] || exit 0
  # The transcript tags each prompt with origin.kind; a background-task wake-up is "task-notification".
  pid=$(field '.prompt_id // empty')
  transcript=$(field '.transcript_path // empty')
  if [[ -n "$pid" && -r "$transcript" ]]; then
    kind=$(grep -F "\"promptId\":\"$pid\"" "$transcript" 2>/dev/null |
      jq -r 'select(.type == "user" and .origin != null) | .origin.kind' 2>/dev/null | head -1)
    [[ "$kind" != "task-notification" ]] || exit 0
  fi
  FOCUSED_SOUND="${CLAUDE_FOCUSED_SOUND:-/run/current-system/sw/share/sounds/freedesktop/stereo/complete.oga}"
  UNFOCUSED_SOUND="${CLAUDE_UNFOCUSED_SOUND:-${HOOKS_DIR}/sounds/done-chime.ogg}"
fi

# --- Per-session debounce ---------------------------------------------------
mkdir -p "$STATE_DIR"
# One debounce file per session and event; drop the ones from sessions older than a week.
find "$STATE_DIR" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null
lock="${STATE_DIR}/last-play-${event}-${sid:-global}"
now=$(date +%s)
if [[ -f "$lock" ]]; then
  last=$(cat "$lock" 2>/dev/null || echo 0)
  if [[ "$last" =~ ^[0-9]+$ ]] && ((now - last < DEBOUNCE_SECS)); then
    exit 0
  fi
fi
printf '%s\n' "$now" >"$lock"

# KWin answers through kdotool, niri through `niri msg`. Over SSH the focused window is on
# another machine, so the cue counts as unfocused and the popup reaches Omer's Ghostty there.
is_focused=0
if [[ -z "${SSH_CONNECTION:-}" ]]; then
  active_class=$(timeout 5 kdotool getactivewindow getwindowclassname 2>/dev/null)
  if [[ -z "$active_class" ]]; then
    active_class=$(timeout 5 niri msg --json focused-window 2>/dev/null | jq -r '.app_id // empty' 2>/dev/null)
  fi
  if [[ -n "$active_class" ]]; then
    [[ "${active_class,,}" == *ghostty* ]] && is_focused=1
  # NixOS wraps Ghostty, so its process name is the wrapper's, cut to 15 characters.
  elif pgrep -x 'ghostty|\.ghostty-wrappe' >/dev/null 2>&1; then
    is_focused=1
  fi
fi

if [[ "$is_focused" -eq 1 ]]; then
  sound="$FOCUSED_SOUND"
else
  sound="$UNFOCUSED_SOUND"
fi

# Controlling TTY of the parent claude process, read from /proc (walk up a few frames).
# /proc/<pid>/stat after the ") " is: state ppid pgrp session tty_nr ...; tty_nr packs the device
# number (major 136-143 is /dev/pts/N, major 4 is /dev/ttyN).
session_tty() {
  local pid="${PPID:-}" stat ppid tty_nr major minor _
  for _ in 1 2 3 4 5 6 7 8; do
    [[ -n "$pid" && "$pid" -gt 1 && -r "/proc/$pid/stat" ]] || return 1
    stat="$(<"/proc/$pid/stat")"
    read -r _ ppid _ _ tty_nr _ <<<"${stat##*) }"
    major=$(((tty_nr >> 8) & 0xfff))
    minor=$(((tty_nr & 0xff) | ((tty_nr >> 12) & 0xfff00)))
    if ((major >= 136 && major <= 143)); then
      printf '/dev/pts/%d' $(((major - 136) * 256 + minor))
      return 0
    elif ((major == 4)); then
      printf '/dev/tty%d' "$minor"
      return 0
    fi
    pid="$ppid"
  done
  return 1
}

# Desktop notification through Ghostty (OSC 777): clicking it focuses this session's tab.
# Claude Code's own terminal notifications are off (preferredNotifChannel), so this is the only one.
notify_tab() {
  local dev title body
  dev=$(session_tty) || return 0
  [[ -w "$dev" ]] || return 0
  title="Claude Code: $(basename "$(field '.cwd // empty')")"
  if [[ "$event" == "Notification" ]]; then
    body=$(field '.message // "Needs your input"')
  else
    body=$(field '(.last_assistant_message // "") | split("\n") | map(select(test("\\S"))) | first // "Finished"')
  fi
  # OSC 777 ends at BEL and splits title from body at the first ';'.
  title=$(tr -d '\000-\037\177;' <<<"$title")
  body=$(tr -d '\000-\037\177`*#' <<<"$body")
  body="${body:0:160}"
  printf '\033]777;notify;%s;%s\007' "$title" "${body:-Finished}" >"$dev" 2>/dev/null || true
}

if [[ "$is_focused" -eq 0 ]]; then
  notify_tab
fi

play_sound() {
  local file="$1"
  # Detach from the hook process group so the hook timeout cannot cut the cue.
  if command -v ffplay >/dev/null 2>&1; then
    setsid ffplay -nodisp -autoexit -loglevel quiet -nostats "$file" </dev/null >/dev/null 2>&1 &
    return
  fi
  if command -v mpv >/dev/null 2>&1; then
    setsid mpv --no-video --really-quiet "$file" </dev/null >/dev/null 2>&1 &
    return
  fi
  if command -v paplay >/dev/null 2>&1; then
    setsid paplay "$file" </dev/null >/dev/null 2>&1 &
    return
  fi
  if command -v pw-play >/dev/null 2>&1; then
    setsid pw-play "$file" </dev/null >/dev/null 2>&1 &
  fi
}

if [[ -f "$sound" ]]; then
  play_sound "$sound"
fi

exit 0
