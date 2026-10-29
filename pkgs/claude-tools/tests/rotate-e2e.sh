#!/usr/bin/env bash
set -euo pipefail
tools="$(readlink -f "${1:?usage: $0 BIN-DIR}")/claude-tools"
profiles() { "$tools" accounts "$@"; }
A="${CR_E2E_A:-work1-team}" C="${CR_E2E_C:-work2}" R="${CR_E2E_R:-work1}"
dir=$(mktemp -d /tmp/cr-e2e.XXXXXX)
mkdir -p "$dir/cache"
run="cr-e2e-$(basename "$dir" | cut -d. -f2 | tr '[:upper:]' '[:lower:]')"
t() { tmux -L "$run" "$@"; }
ok=0

cleanup() {
  t kill-server 2>/dev/null || true
  local w
  for w in ${wrapper:-} ${mwrapper:-}; do
    rm -f "${XDG_RUNTIME_DIR:-/tmp/claude-tools-$(id -u)}/claude-tools/rotate/$w-"*.json
  done
  if ((ok)); then rm -rf "$dir"; else echo "kept $dir"; fi
}
trap cleanup EXIT
fail() {
  echo "FAIL: $*"
  t capture-pane -p -t "$run" 2>/dev/null | grep -v '^\s*$' | tail -12 >"$dir/pane.log" || true
  t capture-pane -p -t "$run-m" 2>/dev/null | grep -v '^\s*$' | tail -12 >"$dir/pane-move.log" || true
  exit 1
}

for n in "$A" "$C" "$R"; do
  profiles names | grep -qx "$n" || fail "no account $n here"
done

"$tools" usage --json --max-age 600 >"$dir/real-usage.json"
jq --arg a "$A" --arg c "$C" --arg r "$R" --argjson now "$(date +%s)" '
  def w($u): {used: $u, resets_at: ($now + 3600)};
  .updated = $now | .hosts = []
  | .accounts |= map(.state = "ok" | .five_hour = w(95) | .seven_day = w(95)
      | if .name == $a then .five_hour = w(1) | .seven_day = w(1)
        elif .name == $c then .five_hour = w(0) | .seven_day = w(0)
        elif .name == $r then .five_hour = w(1) | .seven_day = {used: 1, resets_at: ($now + 6 * 86400)} else . end)' \
  "$dir/real-usage.json" >"$dir/cache/usage.json"
mkdir -p "$dir/state"
jq -n --arg c "$C" --argjson u "$(($(date +%s) + 3600))" '{($c): {until: $u, reason: "e2e seed"}}' >"$dir/state/limits.json"

t new-session -d -s "$run" -x 200 -y 50 \
  "cd $dir && exec env -u CLAUDE_CONFIG_DIR -u CLAUDE_TOOLS_ROTATE_ID CLAUDE_TOOLS_CACHE=$dir/cache \
CLAUDE_TOOLS_STATE=$dir/state $tools rotate --model haiku \
--dangerously-skip-permissions"
t set-option -t "$run" remain-on-exit on
wrapper=$(t display -p -t "$run" '#{pane_pid}')

picker() {
  local screen
  for _ in $(seq 30); do
    screen=$(t capture-pane -p -t "$1")
    grep -q "choose the account for this session" <<<"$screen" && {
      echo "$screen"
      return
    }
    sleep 1
  done
  fail "the account picker did not open in 30 s"
}
screen=$(picker "$run")
grep -q "^ ❯ 1  $A .*★ " <<<"$screen" || fail "the picker does not hold $A first under the cursor"
grep -A1 -- "── reserve: weekly limit" <<<"$screen" | grep -q "^   2  $R .*reserve · week resets in" ||
  fail "the picker does not put the weekly-limited $R after the team account $A, under the reserve line"
grep -q "^   [0-9]  $C .*held back after a limit" <<<"$screen" || fail "the picker does not show $C as held back"
t send-keys -t "$run" Down
sleep 1
! grep -q "^ ❯ [0-9]  $A " <<<"$(t capture-pane -p -t "$run")" || fail "Down did not move the cursor off $A"
t send-keys -t "$run" Up
sleep 1
grep -q "^ ❯ [0-9]  $A " <<<"$(t capture-pane -p -t "$run")" || fail "Up did not bring the cursor back to $A"
t send-keys -t "$run" Enter

child() {
  local p env w="${1:-$wrapper}"
  for p in $(pgrep -x 'claude|\.claude-wrapped'); do
    env=$(tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null) || continue
    grep -qx "CLAUDE_TOOLS_ROTATE_ID=$w" <<<"$env" || continue
    [[ "$(awk '{print $4}' "/proc/$p/stat")" == "$w" ]] || continue
    printf '%s\t%s\t%s\n' "$p" "$(sed -n 's/^CLAUDE_CONFIG_DIR=//p' <<<"$env")" "$(tr '\0' ' ' <"/proc/$p/cmdline")"
    return
  done
}
account_of() {
  local n
  for n in $(profiles names); do [[ "$(profiles dir "$n")" == "$1" ]] && {
    echo "$n"
    return
  }; done
  echo "unknown:$1"
}
type_line() {
  t send-keys -t "${2:-$run}" -l "$1"
  sleep 1
  t send-keys -t "${2:-$run}" Enter
}
settle() {
  local screen session="${1:-$run}"
  for _ in $(seq 60); do
    screen=$(t capture-pane -p -t "$session")
    if grep -q "Yes, I trust this folder" <<<"$screen"; then
      t send-keys -t "$session" Down Enter
      sleep 3
      continue
    fi
    grep -q '^❯' <<<"$screen" && [[ -n "$(child "${2:-$wrapper}")" ]] && return
    sleep 1
  done
  fail "claude did not reach its input box in 60 s"
}
settle
first=$(child)
[[ -n "$first" ]] || fail "claude-tools rotate started no claude"
[[ "$(account_of "$(cut -f2 <<<"$first")")" == "$A" ]] || fail "the session started on $(account_of "$(cut -f2 <<<"$first")"), not $A"
argv=$(cut -f3 <<<"$first")
grep -q -- "--model haiku" <<<"$argv" || fail "the session dropped --model haiku: $argv"
grep -q -- "--dangerously-skip-permissions" <<<"$argv" || fail "the session dropped --dangerously-skip-permissions: $argv"
echo "start: the picker held $C back and started $A on enter"

type_line "/exit"
for _ in $(seq 20); do
  [[ -d "/proc/$wrapper" ]] || break
  sleep 1
done
[[ ! -d "/proc/$wrapper" ]] || fail "claude-tools rotate still runs 20 s after /exit"
[[ "$(t display -p -t "$run" '#{pane_dead_status}')" == 0 ]] || fail "claude-tools rotate exited $(t display -p -t "$run" '#{pane_dead_status}')"
[[ -z "$(child)" ]] || fail "a claude of this run outlived /exit"
echo "exit: /exit ended claude-tools rotate with exit code 0"

t new-session -d -s "$run-q" -x 200 -y 50 \
  "cd $dir && exec env -u CLAUDE_CONFIG_DIR -u CLAUDE_TOOLS_ROTATE_ID CLAUDE_TOOLS_CACHE=$dir/cache \
CLAUDE_TOOLS_STATE=$dir/state $tools rotate --model haiku"
t set-option -t "$run-q" remain-on-exit on
picker "$run-q" >/dev/null
t send-keys -t "$run-q" q
for _ in $(seq 10); do
  [[ "$(t display -p -t "$run-q" '#{pane_dead}')" == 1 ]] && break
  sleep 1
done
[[ "$(t display -p -t "$run-q" '#{pane_dead}')" == 1 ]] || fail "claude-tools rotate still runs 10 s after q in its picker"
[[ "$(t display -p -t "$run-q" '#{pane_dead_status}')" == 0 ]] ||
  fail "q made claude-tools rotate exit $(t display -p -t "$run-q" '#{pane_dead_status}')"
echo "quit: q in the picker started nothing"

m="$run-m" mstate="$dir/move-state" sid=$(cat /proc/sys/kernel/random/uuid)
mkdir -p "$mstate" "$dir/move-cache"
cp "$dir/real-usage.json" "$dir/move-cache/usage.json"
menv="CLAUDE_TOOLS_CACHE=$dir/move-cache CLAUDE_TOOLS_STATE=$mstate"
order() { env CLAUDE_TOOLS_CACHE="$dir/move-cache" CLAUDE_TOOLS_STATE="$mstate" "$tools" usage --order "$@" | head -n 1; }
t new-session -d -s "$m" -x 200 -y 50 \
  "cd $dir && exec env -u CLAUDE_CONFIG_DIR -u CLAUDE_TOOLS_ROTATE_ID CLAUDE_TOOLS_PICK=0 $menv \
$tools rotate --session-id $sid --model haiku --dangerously-skip-permissions"
t set-option -t "$m" remain-on-exit on
mwrapper=$(t display -p -t "$m" '#{pane_pid}')
runtime="${XDG_RUNTIME_DIR:-/tmp/claude-tools-$(id -u)}/claude-tools/rotate"
settle "$m" "$mwrapper"
type_line "Reply only OK." "$m"
for _ in $(seq 60); do
  transcript=$(ls ~/.claude/projects/*/"$sid".jsonl 2>/dev/null) && break
  sleep 1
done
[[ -n "${transcript:-}" ]] || fail "session $sid wrote no transcript"
quiet() {
  local size=-1 now
  for _ in $(seq 120); do
    now=$(stat -c %s "$transcript")
    ((now == size)) && jq -se '[.[] | select(.type == "user" or .type == "assistant")] | last | .type == "assistant"' \
      "$transcript" >/dev/null && return
    size=$now
    sleep 5
  done
  fail "the transcript of $sid did not settle in 600 s"
}
limit() {
  local c tmp
  c=$(child "$mwrapper" | cut -f1)
  tmp=$(mktemp "$runtime/.e2e.XXXXXX")
  jq -n --arg s "$sid" --arg t "$transcript" --arg m "You've hit your session limit · resets $1 (UTC)" \
    '{session_id: $s, transcript_path: $t, hook_event_name: "StopFailure", last_assistant_message: $m}' >"$tmp"
  mv "$tmp" "$runtime/$mwrapper-$c.json"
}
moved() {
  local c
  for _ in $(seq "$2"); do
    c=$(child "$mwrapper")
    [[ -n "$c" && "$(cut -f1 <<<"$c")" != "$1" ]] && grep -q -- "--resume $sid" <<<"$(cut -f3 <<<"$c")" && {
      echo "$c"
      return
    }
    sleep 1
  done
}
hold_others() {
  profiles names | jq -R . | jq -s --arg keep "$1" --argjson u "$2" \
    'map(select(. != $keep) | {(.): {until: $u, reason: "e2e hold"}}) | add' >"$mstate/limits.json.e2e"
  flock "$mstate/limits.lock" mv "$mstate/limits.json.e2e" "$mstate/limits.json"
}
quiet
first=$(child "$mwrapper")
A=$(account_of "$(cut -f2 <<<"$first")")
reset=$(date -u -d '+2 hours' +%s)
reset=$((reset - reset % 60))
limit "$(LC_ALL=C date -u -d "@$reset" +%-I:%M%P)"
next=$(moved "$(cut -f1 <<<"$first")" 300)
[[ -n "$next" ]] || fail "claude-tools rotate did not resume $sid on another account in 300 s after the limit on $A"
B=$(account_of "$(cut -f2 <<<"$next")")
[[ "$B" == "$(order --skip "$A")" ]] || fail "the session moved to $B, not to $(order --skip "$A"), the first of the order"
jq -e --arg a "$A" --argjson u "$reset" '.[$a].until == $u' "$mstate/limits.json" >/dev/null ||
  fail "the hold file does not hold $A until $(date -d "@$reset" -Iseconds): $(jq -c . "$mstate/limits.json")"
echo "move: the limit on $A held it until $(date -d "@$reset" -Iseconds) and resumed $sid on $B"

settle "$m" "$mwrapper"
quiet
[[ -n "$(order --skip "$B")" ]] || fail "no account other than $B has room, so the wait step cannot run"
free=$(($(date +%s) + 90))
hold_others "$B" "$free"
limit "$(LC_ALL=C date -u -d "@$reset" +%-I:%M%P)"
for _ in $(seq 120); do
  grep -q "picking again at" "$mstate/rotate/events.log" 2>/dev/null && break
  sleep 1
done
grep -q "session $sid: no account is free; picking again at $(date -d "@$free" -Iseconds)" "$mstate/rotate/events.log" ||
  fail "claude-tools rotate did not wait until $(date -d "@$free" -Iseconds): $(grep 'picking again' "$mstate/rotate/events.log")"
now=$(date +%s)
((now < free)) || fail "the wait was set up only after the wake time"
next2=$(moved "$(cut -f1 <<<"$next")" $((free - now + 300)))
[[ -n "$next2" ]] || fail "claude-tools rotate did not resume $sid once the holds ended"
B2=$(account_of "$(cut -f2 <<<"$next2")")
[[ "$B2" == "$(order)" ]] || fail "after the wait the session resumed on $B2, not on $(order), the first of the order"
echo "wait: no account was free until $(date -d "@$free" -Iseconds); then $sid resumed on $B2"

settle "$m" "$mwrapper"
quiet
free=$(($(date +%s) + 90))
hold_others "$B2" "$free"
limit "$(LC_ALL=C date -u -d "@$reset" +%-I:%M%P)"
for _ in $(seq 120); do
  (($(grep -c "picking again at" "$mstate/rotate/events.log") == 2)) && break
  sleep 1
done
(($(grep -c "picking again at" "$mstate/rotate/events.log") == 2)) || fail "the second limit started no wait"
type_line "Reply only OK again." "$m"
now=$(date +%s)
((now < free)) || fail "the prompt went in only after the wake time"
sleep $((free - now + 30))
[[ "$(child "$mwrapper" | cut -f1)" == "$(cut -f1 <<<"$next2")" ]] || fail "claude-tools rotate restarted a session that went on by hand"
grep -q "session $sid: a prompt went in after the limit; no move" "$mstate/rotate/events.log" ||
  fail "claude-tools rotate did not log the prompt typed during the wait"
echo "typed: a prompt during the wait kept $sid on $B2"
ok=1
echo PASS
