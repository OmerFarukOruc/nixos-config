#!/usr/bin/env bash
set -euo pipefail
tools="$(readlink -f "${1:?usage: $0 BIN-DIR}")/claude-tools"
dir=$(mktemp -d /tmp/cls-e2e.XXXXXX)
run="cls-e2e-$(basename "$dir" | cut -d. -f2 | tr '[:upper:]' '[:lower:]')"
export CLAUDE_TOOLS_HERDR_SESSION="$run" CLAUDE_TOOLS_STATE="$dir/state"
state="$dir/state/limit-switch"
cls() { "$tools" limit-switch "$@"; }
profiles() { "$tools" accounts "$@"; }
sock="$HOME/.config/herdr/sessions/$run/herdr.sock"
name="$run"
h() { herdr --session "$run" "$@"; }

cleanup() {
  h agent prompt "$name" /exit >/dev/null 2>&1 || true
  sleep 3
  h server stop >/dev/null 2>&1 || true
  sleep 2
  herdr session delete "$run" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() {
  echo "FAIL: $*"
  exit 1
}

claude_in() {
  local p env
  for p in $(pgrep -x 'claude|\.claude-wrapped'); do
    env=$(tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null) || continue
    if grep -qx "HERDR_PANE_ID=$1" <<<"$env" && grep -qx "HERDR_SOCKET_PATH=$sock" <<<"$env"; then
      printf '%s\t%s\n' "$(sed -n 's/^CLAUDE_CONFIG_DIR=//p' <<<"$env")" "$(tr '\0' ' ' <"/proc/$p/cmdline")"
      return
    fi
  done
}
account() {
  local d n
  d=$(claude_in "$1" | cut -f1)
  for n in $(profiles names); do [[ "$(profiles dir "$n")" == "$d" ]] && {
    echo "$n"
    return
  }; done
  fail "pane $1 runs an unknown CLAUDE_CONFIG_DIR '$d'"
}
session() { h agent get "$name" | jq -r '.result.agent.agent_session.value'; }
ask() { h agent prompt "$name" "$1" --wait --timeout 180000 >/dev/null; }
check_word() {
  ask "What was the code word I gave you at the start? Reply with only the code word followed directly by the digit 7, no space."
  local t
  t=$(ls ~/.claude/projects/*/"$sid".jsonl)
  for _ in $(seq 30); do
    jq -r 'select(.type == "assistant") | .message.content[]? | .text? // empty' "$t" | tail -1 | grep -q -i pelican7 && return
    sleep 2
  done
  fail "the agent lost the code word after $1"
}
check_agent() {
  h agent wait "$name" --timeout 180000 >/dev/null
  [[ "$(session)" == "$sid" ]] || fail "$1 changed the session id"
  claude_in "$pane" | cut -f2 | grep -q -- "--model haiku" || fail "$1 dropped --model haiku"
  claude_in "$pane" | cut -f2 | grep -q -- "--dangerously-skip-permissions" || fail "$1 dropped --dangerously-skip-permissions"
  check_word "$1"
}
check_loop() {
  ask "Run CronList and reply with only the number of scheduled jobs followed directly by the letter j, no space."
  local t
  t=$(ls ~/.claude/projects/*/"$sid".jsonl)
  for _ in $(seq 30); do
    jq -r 'select(.type == "assistant") | .message.content[]? | .text? // empty' "$t" | tail -1 | grep -q 1j && return
    sleep 2
  done
  fail "the agent does not have exactly one scheduled job after $1"
}
check_move() {
  local now
  now=$(account "$pane")
  [[ "$now" != "$2" && "$now" != work2 ]] || fail "$1 left the agent on $now"
  check_agent "$1"
  echo "$1: moved from $2 to $now"
}

cls restore || fail "restore could not start the $run server"
ws_json=$(h workspace create --cwd "$dir" --label "$run" --env "CLAUDE_CONFIG_DIR=$(profiles dir work1-team)" --no-focus)
pane=$(jq -r .result.root_pane.pane_id <<<"$ws_json")
for _ in $(seq 60); do
  out=$(h agent start "$name" --kind claude --pane "$pane" --timeout 120000 -- --dangerously-skip-permissions --model haiku 2>&1) && break
  grep -q agent_pane_busy <<<"$out" || break
  sleep 1
done
if grep -q agent_not_ready <<<"$out"; then
  h agent read "$name" --source visible | grep -q "Yes, I trust this folder" || fail "start blocked: $out"
  h agent send-keys "$name" down >/dev/null
  h agent send-keys "$name" enter >/dev/null
fi
h agent wait "$name" --until idle --timeout 60000 >/dev/null
[[ "$(account "$pane")" == work1-team ]] || fail "scratch agent did not start on work1-team"
ask "Remember the code word PELICAN. Reply only OK."
h agent prompt "$name" "/loop 6h reply only with the word tick" >/dev/null 2>&1 || true
sleep 3
h agent read "$name" --source visible | grep -q '❯ /loop' && h agent send-keys "$name" enter >/dev/null
h agent wait "$name" --until idle --until "done" --until blocked --timeout 120000 >/dev/null
if h agent read "$name" --source visible | grep -q "This session only"; then
  h agent send-keys "$name" down >/dev/null
  h agent send-keys "$name" enter >/dev/null
fi
h agent wait "$name" --until idle --until "done" --timeout 120000 >/dev/null ||
  {
    h agent read "$name" --source visible | tail -15
    fail "the /loop prompt did not settle"
  }
sid=$(session)
[[ -n "$sid" && "$sid" != null ]] || fail "herdr reports no session id"

jq -n --argjson u "$(($(date +%s) + 3600))" '{work2: {until: $u, reason: "e2e seed"}}' >"$state/limits.json"

cls switch "$name" || fail "switch exited $?"
first=$(account "$pane")
check_move switch work1-team
grep -q "answered the background-work dialog of $name" "$state/events.log" ||
  fail "switch did not answer the background-work dialog"
answered=$(date -d "$(grep -m1 "answered the background-work dialog of $name" "$state/events.log" | cut -d' ' -f1)" +%s)
moved=$(date -d "$(grep -m1 "$name: moved from" "$state/events.log" | cut -d' ' -f1)" +%s)
((moved - answered < 25)) || fail "the move came $((moved - answered)) s after the dialog answer, so Enter did not end claude"
check_loop switch

rm -f "$state/switched.json"
cls scan || fail "scan exited $?"
[[ "$(account "$pane")" == "$first" ]] || fail "scan moved an agent whose screen shows no limit to $(account "$pane")"
jq -e --arg n "$name" '.agents[$n].session' "$state/agents.json" >/dev/null || fail "scan did not record $name"

h server stop >/dev/null
for _ in $(seq 30); do
  [[ -z "$(claude_in "$pane")" ]] && break
  sleep 1
done
[[ -z "$(claude_in "$pane")" ]] || fail "claude outlived the stopped server"
cls scan || fail "scan after the server stop exited $?"
[[ "$(account "$pane")" == "$first" ]] || fail "restore put the agent on $(account "$pane"), not $first"
check_agent restore
echo "restore: back in $pane on $first"

ask "Delete every scheduled job with CronDelete. Reply only OK."
h agent prompt "$name" /exit >/dev/null
for _ in $(seq 30); do
  [[ -z "$(claude_in "$pane")" ]] && break
  sleep 1
done
cls scan || fail "scan after the exit exited $?"
[[ -z "$(claude_in "$pane")" ]] || fail "scan started an agent that exited on purpose"
jq -e --arg n "$name" --arg s "$sid" '(.agents | has($n) | not) and .ended[$n].session == $s' \
  "$state/agents.json" >/dev/null ||
  fail "the record does not hold $name as ended: $(jq -c . "$state/agents.json")"
echo "exit: $name stays gone and is recorded as ended"

h workspace close "$(jq -r .result.workspace.workspace_id <<<"$ws_json")" >/dev/null
cls resume "$name" || fail "resume exited $?"
new_pane=$(h agent get "$name" | jq -r .result.agent.pane_id)
[[ "$new_pane" != "$pane" ]] || fail "resume reused the closed pane $pane"
pane=$new_pane
[[ "$(account "$pane")" == "$first" ]] || fail "resume put the agent on $(account "$pane"), not $first"
check_agent resume
jq -e --arg n "$name" '(.agents | has($n)) and (.ended | has($n) | not)' "$state/agents.json" >/dev/null ||
  fail "the record still holds $name as ended after resume"
pid=$(for p in $(pgrep -x 'claude|\.claude-wrapped'); do
  env=$(tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null) || continue
  if grep -qx "HERDR_PANE_ID=$pane" <<<"$env" && grep -qx "HERDR_SOCKET_PATH=$sock" <<<"$env"; then echo "$p"; fi
done)
cls resume "$name" || fail "resume of the running agent exited $?"
[[ -n "$pid" && -d "/proc/$pid" ]] || fail "resume of the running agent restarted it"
cls resume nobody-e2e && fail "resume of an unknown name exited 0"
echo "resume: back in new pane $pane on $first"

h agent prompt "$name" /exit >/dev/null
for _ in $(seq 30); do
  [[ -z "$(claude_in "$pane")" ]] && break
  sleep 1
done
cls resume "$name" || fail "resume right after /exit exited $?"
[[ -n "$(claude_in "$pane")" ]] || fail "resume right after /exit started nothing"
check_agent "resume right after /exit"
echo "resume right after /exit: back in $pane"
echo PASS
