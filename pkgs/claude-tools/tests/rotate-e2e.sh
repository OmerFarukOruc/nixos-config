#!/usr/bin/env bash
set -euo pipefail
tools="$(readlink -f "${1:?usage: $0 BIN-DIR}")/claude-tools"
profiles() { "$tools" accounts "$@"; }
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

"$tools" usage --json --max-age 600 >"$dir/real-usage.json"
R=${CR_E2E_R:-$(jq -r 'first(.accounts[] | select(.plan != null and (.state == "ok" or .state == "expiring")) | .name) // empty' \
  "$dir/real-usage.json")}
other() { profiles names | awk -v r="$R" -v a="${A:-}" '$0 != r && $0 != a { print; exit }'; }
A=${CR_E2E_A:-$(other)}
C=${CR_E2E_C:-$(other)}
[[ -n $A && -n $C && -n $R ]] || fail "rotate-e2e needs a signed-in account and two more accounts; set CR_E2E_R, CR_E2E_A and CR_E2E_C"
for n in "$A" "$C" "$R"; do
  profiles names | grep -qx "$n" || fail "no account $n here"
done
D=$(profiles names | grep -vxF -e "$A" -e "$C" -e "$R" | head -n 1) M=e2e-no-folder
[[ -n "$D" ]] || fail "no fourth account here to leave out of accounts.json"
mkdir -p "$dir/data"
jq --arg d "$D" --arg m "$M" 'del(.accounts[$d]) | .accounts[$m] = {email: "e2e@example.invalid", org: "personal"}' \
  "${CLAUDE_TOOLS_DATA:-$HOME/.config/claude-tools}/accounts.json" >"$dir/data/accounts.json"

jq --arg a "$A" --arg c "$C" --arg r "$R" --arg d "$D" --argjson now "$(date +%s)" '
  def w($u): {used: $u, resets_at: ($now + 3600)};
  .updated = $now | .hosts = []
  | .accounts |= map(select(.name != $d) | .state = "ok" | del(.checked) | .five_hour = w(95) | .seven_day = w(95)
      | if .name == $a then .plan = "team 5x" | .checked = $now | .five_hour = {used: 1, resets_at: ($now + 4 * 3600)}
          | .seven_day = {used: 93, resets_at: ($now + 3 * 86400)}
        elif .name == $c then .five_hour = w(0) | .seven_day = w(0)
        elif .name == $r then .checked = $now | .five_hour = w(1) | .seven_day = {used: 1, resets_at: ($now + 6 * 86400)} else . end)' \
  "$dir/real-usage.json" >"$dir/cache/usage.json"
mkdir -p "$dir/state"
jq -n --arg c "$C" --argjson u "$(($(date +%s) + 3600))" '{($c): {until: $u, reason: "e2e seed"}}' >"$dir/state/limits.json"

t new-session -d -s "$run" -x 200 -y 50 \
  "cd $dir && exec env -u CLAUDE_CONFIG_DIR -u CLAUDE_TOOLS_ROTATE_ID CLAUDE_TOOLS_CACHE=$dir/cache \
CLAUDE_TOOLS_STATE=$dir/state CLAUDE_TOOLS_DATA=$dir/data $tools rotate --model haiku \
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
! grep -q "^.\{6\}$D " <<<"$screen" || fail "the picker lists $D, which accounts.json does not list"
grep -q "^      $M .*no login here · claude-tools accounts login $M" <<<"$screen" ||
  fail "the picker does not show $M, which accounts.json lists and this host has no folder for, as unpickable"
grep -q "^ ❯ 1  $R .*★ " <<<"$screen" || fail "the picker does not hold $R first under the cursor"
grep -A1 -- "── reaches a limit before its 5h reset" <<<"$screen" | grep -q "^   2  $A .*7d limit in about" ||
  fail "the picker does not put the team account $A, whose week is at 93%, after $R, under the reaches-a-limit line"
grep -q "^   [0-9]  $C .*held back after a limit" <<<"$screen" || fail "the picker does not show $C as held back"
t send-keys -t "$run" Down
sleep 1
! grep -q "^ ❯ [0-9]  $R " <<<"$(t capture-pane -p -t "$run")" || fail "Down did not move the cursor off $R"
t send-keys -t "$run" Up
sleep 1
grep -q "^ ❯ [0-9]  $R " <<<"$(t capture-pane -p -t "$run")" || fail "Up did not bring the cursor back to $R"
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
[[ "$(account_of "$(cut -f2 <<<"$first")")" == "$R" ]] || fail "the session started on $(account_of "$(cut -f2 <<<"$first")"), not $R"
argv=$(cut -f3 <<<"$first")
grep -q -- "--model haiku" <<<"$argv" || fail "the session dropped --model haiku: $argv"
grep -q -- "--dangerously-skip-permissions" <<<"$argv" || fail "the session dropped --dangerously-skip-permissions: $argv"
echo "start: the picker held $C back and started $R on enter"

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
CLAUDE_TOOLS_STATE=$dir/state CLAUDE_TOOLS_DATA=$dir/data $tools rotate --model haiku"
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
  jq -n --arg s "$sid" --arg t "$transcript" --arg m "You've hit your 5-hour limit · resets $1 (UTC)" \
    '{session_id: $s, transcript_path: $t, hook_event_name: "StopFailure", last_assistant_message: $m}' >"$dir/limit.json"
  type_line "! ${tools%/bin/claude-tools}/libexec/claude-tools/rotate-on-limit < $dir/limit.json" "$m"
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
echo "move: the limit on $A resumed $sid on $B, the first of the order"
ok=1
echo PASS
