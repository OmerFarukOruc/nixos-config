#!/usr/bin/env bash
set -euo pipefail
tools="$(readlink -f "${1:?usage: $0 BIN-DIR}")/claude-tools"
grep -qx 'resume_agents_on_restore = false' "${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}" || {
  echo "FAIL: herdr restores Claude panes itself on this host, so the restore step cannot pass; run this where claude-tools-limit-switch runs (devbox)"
  exit 1
}
dir=$(mktemp -d /tmp/cls-e2e.XXXXXX)
run="cls-e2e-$(basename "$dir" | cut -d. -f2 | tr '[:upper:]' '[:lower:]')"
export CLAUDE_TOOLS_HERDR_SESSION="$run" CLAUDE_TOOLS_STATE="$dir/state"
state="$dir/state/limit-switch"
cls() { "$tools" limit-switch "$@"; }
profiles() { "$tools" accounts "$@"; }
sock="$HOME/.config/herdr/sessions/$run/herdr.sock"
name="$run"
h() { herdr --session "$run" "$@"; }

ok=0
cleanup() {
  h agent prompt "$name" /exit >/dev/null 2>&1 || true
  sleep 3
  h server stop >/dev/null 2>&1 || true
  sleep 2
  herdr session delete "$run" >/dev/null 2>&1 || true
  if ((ok)); then rm -rf "$dir"; else echo "kept $dir"; fi
}
trap cleanup EXIT
fail() {
  echo "FAIL: $*"
  exit 1
}

mode=${CLS_E2E_AGENT_ARGS:-skip}
if [[ $mode == settings ]]; then
  jq -n '{permissions: {defaultMode: "dontAsk", allow: []}}' >"$dir/settings.json"
  agent_args=(--settings "$dir/settings.json" --permission-mode dontAsk --model haiku)
else
  agent_args=(--dangerously-skip-permissions --model haiku)
fi

claude_in() {
  local p env
  for p in $(pgrep -x 'claude|\.claude-wrapped'); do
    env=$(tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null) || continue
    if grep -qx "HERDR_PANE_ID=$1" <<<"$env" && grep -qx "HERDR_SOCKET_PATH=$sock" <<<"$env"; then
      printf '%s\t%s\t%s\n' "$(sed -n 's/^CLAUDE_CONFIG_DIR=//p' <<<"$env")" "$(tr '\0' ' ' <"/proc/$p/cmdline")" "$p"
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
transcript() { ls ~/.claude/projects/*/"$sid".jsonl; }
transcript_shows() {
  local t out
  t=$(transcript)
  for _ in $(seq 30); do
    out=$(jq -rs "$1" "$t") && grep -q "${@:2}" <<<"$out" && return 0
    sleep 2
  done
  return 1
}
last_reply='[.[] | select(.type == "assistant") | .message.content[]? | .text? // empty] | last // empty'
check_word() {
  ask "What was the code word I gave you at the start? Reply with only the code word followed directly by the digit 7, no space."
  transcript_shows "$last_reply" -i pelican7 || fail "the agent lost the code word after $1"
}
check_agent() {
  h agent wait "$name" --timeout 180000 >/dev/null
  [[ "$(session)" == "$sid" ]] || fail "$1 changed the session id"
  claude_in "$pane" | cut -f2 | grep -q -- "--model haiku" || fail "$1 dropped --model haiku"
  if [[ $mode == settings ]]; then
    cmdline=$(claude_in "$pane" | cut -f2)
    grep -q -- "--settings $dir/settings.json" <<<"$cmdline" || fail "$1 dropped --settings"
    grep -q -- "--permission-mode dontAsk" <<<"$cmdline" || fail "$1 dropped --permission-mode dontAsk"
    ! grep -q -- "--dangerously-skip-permissions" <<<"$cmdline" || fail "$1 added --dangerously-skip-permissions"
  else
    claude_in "$pane" | cut -f2 | grep -q -- "--dangerously-skip-permissions" || fail "$1 dropped --dangerously-skip-permissions"
  fi
  check_word "$1"
}
check_loop() {
  [[ $mode == settings ]] && return 0
  ask "Run CronList and reply with only the number of scheduled jobs followed directly by the letter j, no space."
  transcript_shows "$last_reply" 1j || fail "the agent does not have exactly one scheduled job after $1"
}
check_prompted() {
  transcript_shows '.[] | select(.type == "user") | .message.content | if type == "string" then . else (.[]?.text? // empty) end' \
    -F "The usage limit of your Claude account $1 has reset. Continue where you stopped." ||
    fail "scan did not prompt the agent on its own account $1 to continue"
}
inject_limit() {
  local t parent
  t=$(transcript)
  parent=$(jq -rs '[.[] | select(.uuid)] | last | .uuid' "$t")
  jq -cn --arg text "$1" --arg sid "$sid" --arg cwd "$dir" --arg uuid "$(cat /proc/sys/kernel/random/uuid)" \
    --arg parent "$parent" --arg ts "$(date -u +%FT%T.000Z)" \
    '{parentUuid: $parent, isSidechain: false, userType: "external", cwd: $cwd, sessionId: $sid, type: "assistant",
      uuid: $uuid, timestamp: $ts, error: "rate_limit", apiError: "usage_limit_reached", isApiErrorMessage: true,
      message: {id: $uuid, model: "<synthetic>", role: "assistant", type: "message", stop_reason: "stop_sequence",
        content: [{type: "text", text: $text}]}}' >>"$t"
}
limit_line() { echo "You've hit your 5-hour limit · resets $(LC_ALL=C date -u -d "@$1" +%-I:%M%P) (UTC)"; }
check_move() {
  local now
  now=$(account "$pane")
  [[ "$now" != "$2" && "$now" != "$3" ]] || fail "$1 left the agent on $now"
  check_agent "$1"
  echo "$1: moved from $2 to $now"
}

start=${CLS_E2E_ACCOUNT:-}
if [[ -z $start ]]; then
  for n in $(profiles names); do [[ -d "$(profiles dir "$n")" ]] && start=$n && break; done
fi
[[ -n $start ]] || fail "no account with a folder in accounts.json"
cls restore || fail "restore could not start the $run server"
ws_json=$(h workspace create --cwd "$dir" --label "$run" --env "CLAUDE_CONFIG_DIR=$(profiles dir "$start")" --no-focus)
pane=$(jq -r .result.root_pane.pane_id <<<"$ws_json")
for _ in $(seq 60); do
  out=$(h agent start "$name" --kind claude --pane "$pane" --timeout 120000 -- "${agent_args[@]}" 2>&1) && break
  grep -q agent_pane_busy <<<"$out" || break
  sleep 1
done
if grep -q agent_not_ready <<<"$out"; then
  h agent read "$name" --source visible | grep -q "Yes, I trust this folder" || fail "start blocked: $out"
  h agent send-keys "$name" down >/dev/null
  h agent send-keys "$name" enter >/dev/null
fi
h agent wait "$name" --until idle --timeout 60000 >/dev/null
[[ "$(account "$pane")" == "$start" ]] || fail "scratch agent did not start on $start"
ask "Remember the code word PELICAN. Reply only OK."
sid=$(session)
[[ -n "$sid" && "$sid" != null ]] || fail "herdr reports no session id"
start_loop() {
  local out
  if ! out=$(h agent prompt "$name" "/loop 6h reply only with the word tick" --wait --until working --until blocked \
    --timeout 30000 2>&1); then
    if grep -q agent_prompt_stalled <<<"$out"; then
      h agent send-keys "$name" enter >/dev/null
    else
      echo "setup: herdr agent prompt failed: $out"
    fi
  fi
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
}
for attempt in 1 2 3; do
  [[ $mode == settings ]] && break
  start_loop
  t=$(transcript)
  routines=$(jq -rs '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use"
    and .name == "RemoteTrigger" and .input.action == "create") | .input.body.name // "unnamed"] | join(", ")' "$t")
  [[ -z $routines ]] || fail "the /loop prompt created the cloud routine $routines on $start (transcript $t); \
disable it there with RemoteTrigger update and the body {\"enabled\": false}"
  ask "Run CronList and reply with only the number of scheduled jobs followed directly by the letter j, no space."
  transcript_shows "$last_reply" 1j && break
  ((attempt < 3)) || fail "the agent has no scheduled job after three /loop prompts"
  echo "setup: the /loop prompt did not reach the session, so it is sent again"
done

mkdir -p "$dir/state"
profiles names | jq -R . | jq -s --arg start "$start" --argjson u "$(($(date +%s) + 3600))" \
  'map(select(. != $start) | {(.): {until: $u, reason: "e2e seed"}}) | add' >"$dir/state/limits.json"
cls switch "$name" && fail "switch moved the agent while the hold file held every other account"
[[ "$(account "$pane")" == "$start" ]] || fail "switch left $start while every other account was held"
grep -q "$name: every other account is limited or unreadable; $name stays on $start" \
  "$state/events.log" || fail "switch did not log that it stays"
rm "$dir/state/limits.json"
echo "held: switch kept the agent on $start while the hold file held every other account"
h agent wait "$name" --until idle --timeout 120000 >/dev/null || fail "the agent did not go idle after the held switch"

cls switch "$name" || fail "switch exited $?"
first=$(account "$pane")
check_move switch "$start" "$start"
if [[ $mode != settings ]]; then
  grep -q "answered the background-work dialog of $name" "$state/events.log" ||
    fail "switch did not answer the background-work dialog"
  answered=$(date -d "$(grep -m1 "answered the background-work dialog of $name" "$state/events.log" | cut -d' ' -f1)" +%s)
  moved=$(date -d "$(grep -m1 "$name: moved from" "$state/events.log" | cut -d' ' -f1)" +%s)
  ((moved - answered < 25)) || fail "the move came $((moved - answered)) s after the dialog answer, so Enter did not end claude"
fi
check_loop switch

rm -f "$state/switched.json"
cls scan || fail "scan exited $?"
[[ "$(account "$pane")" == "$first" ]] || fail "scan moved an agent whose transcript records no limit to $(account "$pane")"
jq -e --arg n "$name" '.agents[$n].session' "$state/agents.json" >/dev/null || fail "scan did not record $name"

reset=$(date -u -d '+2 hours' +%s)
reset=$((reset - reset % 60))
ask "Reply with exactly this line and nothing else: $(limit_line "$reset")"
transcript_shows "$last_reply" -F "$(limit_line "$reset")" || fail "the agent did not print the limit line"
rm -f "$state/switched.json"
cls scan || fail "scan after a printed limit line exited $?"
[[ "$(account "$pane")" == "$first" ]] || fail "scan moved an agent that only printed a limit line to $(account "$pane")"
echo "printed limit: scan left the agent on $first"

inject_limit "$(limit_line "$reset")"
rm -f "$state/switched.json"
cls scan || fail "scan after a limit message exited $?"
check_move "scan after a limit" "$first" "$first"
first=$(account "$pane")

old=$(date -u -d '-1 hour' +%s)
inject_limit "$(limit_line "$old")"
rm -f "$state/switched.json"
profiles names | jq -R . | jq -s --arg keep "$first" --argjson u "$(($(date +%s) + 3600))" \
  'map(select(. != $keep) | {(.): {until: $u, reason: "e2e seed"}}) | add' >"$dir/state/limits.json"
cls scan || fail "scan after an old limit message exited $?"
jq -e --arg a "$first" 'has($a) | not' "$dir/state/limits.json" >/dev/null ||
  fail "scan held $first after a limit message whose reset has passed: $(jq -c . "$dir/state/limits.json")"
check_prompted "$first"
rm "$dir/state/limits.json"
check_agent "scan after an old limit message"
echo "old limit: scan held nothing and prompted the agent on $first to continue"

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

[[ $mode == settings ]] || ask "Delete every scheduled job with CronDelete. Reply only OK."
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
out=$(cls resume nobody-e2e) && fail "resume of an unknown name exited 0"
grep -qF "resume failed: no record of nobody-e2e" <<<"$out" || fail "resume of an unknown name failed for another reason: $out"
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
ok=1
echo PASS
