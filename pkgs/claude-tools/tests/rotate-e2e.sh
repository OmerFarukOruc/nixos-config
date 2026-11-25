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
  for w in ${wrapper:-} ${mwrapper:-} ${mwrapper2:-}; do
    rm -f "${XDG_RUNTIME_DIR:-/tmp/claude-tools-$(id -u)}/claude-tools/rotate/$w-"*.json
  done
  if ((ok)); then rm -rf "$dir"; else echo "kept $dir"; fi
}
trap cleanup EXIT
fail() {
  echo "FAIL: $*"
  t capture-pane -p -t "$run" 2>/dev/null | grep -v '^\s*$' | tail -12 >"$dir/pane.log" || true
  t capture-pane -p -t "$run-m1" 2>/dev/null | grep -v '^\s*$' | tail -12 >"$dir/pane-move.log" || true
  exit 1
}

"$tools" usage --json --max-age 600 >"$dir/real-usage.json"
source "$(dirname "$0")/idle-account.sh"
R=${CR_E2E_R:-$(idle_profile)}
other() { profiles names | awk -v r="$R" -v a="${A:-}" '$0 != r && $0 != a { print; exit }'; }
A=${CR_E2E_A:-$(other)}
C=${CR_E2E_C:-$(other)}
[[ -n $A && -n $C && -n $R ]] || fail "rotate-e2e needs a signed-in profile account with room (5h under 70%, week under 80%) and no open claude session, and two more accounts; set CR_E2E_R, CR_E2E_A and CR_E2E_C"
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

m="$run-m" mstate="$dir/move-state"
mkdir -p "$mstate" "$dir/move-cache" "$dir/move-data"
MX=$(idle_profile)
MY=$(idle_profile "$MX")
MA=""
for n in $(profiles names); do
  signed_in "$n" && has_room "$n" && [[ "$n" != "$MX" && "$n" != "$MY" ]] && {
    MA=$n
    break
  }
done
[[ -n "$MA" && -n "$MX" && -n "$MY" ]] ||
  fail "the move step needs three signed-in accounts with room (5h under 70%, week under 80%), two of them profiles without an open claude session"
jq --arg a "$MA" --arg x "$MX" --arg y "$MY" '.accounts |= with_entries(select(.key == $a or .key == $x or .key == $y))' \
  "${CLAUDE_TOOLS_DATA:-$HOME/.config/claude-tools}/accounts.json" >"$dir/move-data/accounts.json"
jq --arg a "$MA" --arg x "$MX" --arg y "$MY" --argjson now "$(date +%s)" '
  def w($u; $left): {used: $u, resets_at: ($now + $left)};
  .updated = ($now + 600) | .hosts = []
  | .accounts |= map(select(.name == $a or .name == $x or .name == $y) | .checked = ($now + 600) | .scoped = []
      | .five_hour = w(10; 3 * 3600) | .seven_day = w(30; 4 * 86400) | if .name == $a then . else .plan = "team 5x" end)' \
  "$dir/real-usage.json" >"$dir/move-cache/usage.json"
menv="CLAUDE_TOOLS_CACHE=$dir/move-cache CLAUDE_TOOLS_STATE=$mstate CLAUDE_TOOLS_DATA=$dir/move-data"
orders() { env CLAUDE_TOOLS_CACHE="$dir/move-cache" CLAUDE_TOOLS_STATE="$mstate" CLAUDE_TOOLS_DATA="$dir/move-data" "$tools" usage --order "$@"; }
declare -A msid mwr mtr mfirst mnext mto
for i in 1 2; do
  msid[$i]=$(cat /proc/sys/kernel/random/uuid)
  t new-session -d -s "$m$i" -x 200 -y 50 \
    "cd $dir && exec env -u CLAUDE_CONFIG_DIR -u CLAUDE_TOOLS_ROTATE_ID CLAUDE_TOOLS_PICK=0 CLAUDE_TOOLS_START_ACCOUNT=$MA $menv \
$tools rotate --session-id ${msid[$i]} --model haiku --dangerously-skip-permissions"
  t set-option -t "$m$i" remain-on-exit on
  mwr[$i]=$(t display -p -t "$m$i" '#{pane_pid}')
  [[ $i == 1 ]] && mwrapper=${mwr[1]} || mwrapper2=${mwr[2]}
done
quiet() {
  local size=-1 now
  for _ in $(seq 120); do
    now=$(stat -c %s "$1")
    ((now == size)) && jq -se '[.[] | select(.type == "user" or .type == "assistant")] | last | .type == "assistant"' \
      "$1" >/dev/null && return
    size=$now
    sleep 5
  done
  fail "the transcript $1 did not settle in 600 s"
}
moved() {
  local c
  for _ in $(seq "$2"); do
    c=$(child "$3")
    [[ -n "$c" && "$(cut -f1 <<<"$c")" != "$1" ]] && grep -q -- "--resume $4" <<<"$(cut -f3 <<<"$c")" && {
      echo "$c"
      return
    }
    sleep 1
  done
}
hook_input() {
  jq -n --arg s "${msid[$1]}" --arg t "${mtr[$1]}" --arg m "$2" \
    '{session_id: $s, transcript_path: $t, hook_event_name: "StopFailure", last_assistant_message: $m}' >"$dir/limit-$1.json"
  t send-keys -t "$m$1" -l "! ${tools%/bin/claude-tools}/libexec/claude-tools/rotate-on-limit < $dir/limit-$1.json"
}
for i in 1 2; do
  settle "$m$i" "${mwr[$i]}"
  type_line "Reply only OK." "$m$i"
done
for i in 1 2; do
  for _ in $(seq 60); do
    mtr[$i]=$(ls ~/.claude/projects/*/"${msid[$i]}".jsonl 2>/dev/null) && break
    sleep 1
  done
  [[ -n "${mtr[$i]}" ]] || fail "session ${msid[$i]} wrote no transcript"
  quiet "${mtr[$i]}"
  mfirst[$i]=$(child "${mwr[$i]}")
  [[ "$(account_of "$(cut -f2 <<<"${mfirst[$i]}")")" == "$MA" ]] || fail "session $i did not start on $MA"
done
reset=$(date -u -d '+2 hours' +%s)
reset=$((reset - reset % 60))
for i in 1 2; do hook_input "$i" "You've hit your 5-hour limit · resets $(LC_ALL=C date -u -d "@$reset" +%-I:%M%P) (UTC)"; done
sleep 1
t send-keys -t "${m}1" Enter
t send-keys -t "${m}2" Enter
for i in 1 2; do
  mnext[$i]=$(moved "$(cut -f1 <<<"${mfirst[$i]}")" 300 "${mwr[$i]}" "${msid[$i]}")
  [[ -n "${mnext[$i]}" ]] || fail "claude-tools rotate did not resume session $i in 300 s after the limit on $MA"
  mto[$i]=$(account_of "$(cut -f2 <<<"${mnext[$i]}")")
done
[[ "$(printf '%s\n' "${mto[1]}" "${mto[2]}" | sort | tr '\n' ' ')" == "$(printf '%s\n' "$MX" "$MY" | sort | tr '\n' ' ')" ]] ||
  fail "two sessions that hit a limit on $MA in the same second moved to ${mto[1]} and ${mto[2]}, not one each to $MX and $MY"
echo "move: two sessions that hit a limit on $MA at once moved to ${mto[1]} and ${mto[2]}"

B=${mto[1]}
quiet "${mtr[1]}"
fable_reset=$(LC_ALL=C date -u -d '+2 days' '+%b %-d, %-I%P')
hook_input 1 "You've hit your Fable limit · resets $fable_reset (UTC)"
sleep 1
t send-keys -t "${m}1" Enter
again=$(moved "$(cut -f1 <<<"${mnext[1]}")" 300 "${mwr[1]}" "${msid[1]}")
[[ -n "$again" ]] || fail "claude-tools rotate did not resume session 1 in 300 s after the Fable limit on $B"
jq -e --arg k "$B:Fable" '.[$k].model == "Fable"' "$mstate/limits.json" >/dev/null ||
  fail "the Fable limit on $B wrote no hold for Fable alone: $(jq -c . "$mstate/limits.json")"
jq -e --arg k "$B" 'has($k) | not' "$mstate/limits.json" >/dev/null || fail "the Fable limit on $B held the whole account"
orders --model haiku | grep -qxF "$B" || fail "usage --order --model haiku leaves out $B, which only Fable holds"
! orders --model claude-fable-5-2 | grep -qxF "$B" || fail "usage --order --model claude-fable-5-2 lists $B, which Fable holds"
echo "model limit: a Fable limit on $B held only Fable there"
ok=1
echo PASS
