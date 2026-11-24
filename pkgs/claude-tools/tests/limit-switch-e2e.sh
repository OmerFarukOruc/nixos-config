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
csid=""
osid=""
cleanup() {
  h agent prompt "$name" /exit >/dev/null 2>&1 || true
  h agent prompt "$run-foreign" /exit >/dev/null 2>&1 || true
  sleep 3
  h server stop >/dev/null 2>&1 || true
  sleep 2
  herdr session delete "$run" >/dev/null 2>&1 || true
  for p in $(ps -u "$(id -u)" -o pid=); do
    [[ "$(readlink "/proc/$p/cwd" 2>/dev/null)" == "$dir"* ]] && kill "$p" 2>/dev/null
  done
  if [[ -n $csid ]]; then find "$HOME/.codex/sessions" -name "rollout-*-$csid.jsonl" -delete 2>/dev/null; fi
  if [[ -n $osid ]]; then (cd "$dir" && OPENCODE_CONFIG_DIR="$dir/opencode" opencode session delete "$osid" >/dev/null 2>&1); fi
  if ((ok)); then
    rm -rf "$dir" "${HOME:?}/.claude/projects/$(tr '/.' '--' <<<"$dir")"
  else
    echo "kept $dir"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
source "$(dirname "$0")/foreign-agent.sh"
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
    env=$(tr '\0' '\n' 2>/dev/null <"/proc/$p/environ") || continue
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

prompt_to() {
  local out
  out=$(h agent prompt "$1" "$2" --wait --timeout 180000 2>&1) && return 0
  grep -q agent_prompt_stalled <<<"$out" || fail "prompt to $1 failed: $out"
  echo "setup: the prompt to $1 stayed in its input box, so Enter is pressed"
  h agent send-keys "$1" enter >/dev/null
  h agent wait "$1" --until working --until blocked --timeout 30000 >/dev/null 2>&1 || true
  h agent wait "$1" --until idle --until "done" --timeout 180000 >/dev/null
}
sid_of() {
  local s
  for _ in $(seq 30); do
    s=$(h agent get "$1" | jq -r '.result.agent.agent_session.value')
    [[ -n $s && $s != null ]] && break
    sleep 1
  done
  echo "$s"
}
name_of() { h agent get "$1" | jq -r '.result.agent.name'; }
said_in() {
  local f
  for _ in $(seq 30); do
    f=$(ls ~/.claude/projects/*/"$1".jsonl 2>/dev/null) && jq -rs "$2" "$f" | grep -q "${@:3}" && return 0
    sleep 2
  done
  return 1
}
proc_in() {
  h pane process-info --pane "$1" |
    jq -r --arg re "$2" '.result.process_info.foreground_processes[] | select(.name | test("^(" + $re + ")$")) | .pid' |
    head -n 1
}
oc_agent=e2e-restore
oc_ready=""
if command -v opencode >/dev/null && [[ -d "$HOME/.config/opencode" ]]; then
  oc_files="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../agents/opencode/agents" && pwd)"
  [[ ! -e "$oc_files/$oc_agent.md" ]] || fail "the checkout has an agent file $oc_agent.md, the name of an agent this test writes"
  mkdir -p "$dir/opencode/agents"
  for entry in "$HOME/.config/opencode"/*; do
    [[ "$(basename "$entry")" == agents ]] || ln -s "$entry" "$dir/opencode/"
  done
  ln -s "$oc_files"/*.md "$dir/opencode/agents/"
  (cd "$dir" && OPENCODE_CONFIG_DIR="$dir/opencode" opencode models --standalone) >"$dir/opencode-models" ||
    fail "opencode models exited $?"
  oc_model=$(grep -m 1 -v -E '[[:space:]|&\\]' "$dir/opencode-models" || true)
  [[ -n "$oc_model" ]] || fail "opencode models lists no model"
  sed "s|^model: .*|model: $oc_model|" "$oc_files/opencode-review.md" >"$dir/opencode/agents/$oc_agent.md"
  oc_ready=1
fi

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
h agent wait "$name" --until idle --until "done" --timeout 60000 >/dev/null
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
h agent wait "$name" --until idle --until "done" --timeout 120000 >/dev/null || fail "the agent did not settle after the held switch"

cls switch "$name" || fail "switch exited $?"
first=$(account "$pane")
check_move switch "$start" "$start"
if [[ $mode != settings ]]; then
  grep -q "answered the background-work dialog of $name" "$state/events.log" ||
    fail "switch did not answer the background-work dialog"
  answered=$(date -d "$(grep -m1 "answered the background-work dialog of $name" "$state/events.log" | cut -d' ' -f1)" +%s)
  moved=$(date -d "$(grep -m1 "$name: moved from" "$state/events.log" | cut -d' ' -f1)" +%s)
  ((moved - answered < 25)) || fail "the move came $((moved - answered)) s after the dialog answer, so the SIGHUP did not end claude"
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

uws=$(h workspace create --cwd "$dir" --label "$run-u" --no-focus)
upane=$(jq -r .result.root_pane.pane_id <<<"$uws")
h pane run "$upane" "unset CLAUDE_CONFIG_DIR CLAUDE_TOOLS_PLAIN; export CLAUDE_TOOLS_PICK=0 ANTHROPIC_MODEL=haiku" >/dev/null
out=$(h agent start "$run-u" --kind claude --pane "$upane" --timeout 120000 -- --dangerously-skip-permissions 2>&1) ||
  { grep -q agent_not_ready <<<"$out" || fail "the rotate agent did not start: $out"; }
if h agent read "$run-u" --source visible | grep -q "Yes, I trust this folder"; then
  h agent send-keys "$run-u" down >/dev/null
  h agent send-keys "$run-u" enter >/dev/null
fi
h agent wait "$run-u" --until idle --until "done" --timeout 120000 >/dev/null
upid=$(claude_in "$upane" | cut -f3)
grep -qx 'CLAUDE_TOOLS_ROTATE_ID=[0-9]*' <(tr '\0' '\n' <"/proc/$upid/environ") || fail "the pane's claude function did not start rotate"
uaccount=$(account "$upane")
h agent rename "$run-u" --clear >/dev/null
[[ "$(name_of "$upane")" == null ]] || fail "the rotate agent kept a herdr name"
prompt_to "$upane" "Remember the code word HERON. Reply only OK."
usid=$(sid_of "$upane")
said_in "$usid" '[.[] | select(.type == "assistant") | .message.model] | last' haiku ||
  fail "the rotate agent's transcript shows no haiku reply under ANTHROPIC_MODEL=haiku"
claude_in "$upane" | cut -f2 | grep -q -- --model && fail "the rotate agent has --model in its arguments, so the restore of the transcript model proves nothing"
echo "setup: unnamed rotate agent in $upane on $uaccount, session $usid, model from the pane shell's ANTHROPIC_MODEL, which the restarted server's shells lack"

cpane=$(jq -r .result.root_pane.pane_id <<<"$(h workspace create --cwd "$dir" --label "$run-cx" --no-focus)")
h agent start "$run-cx" --kind codex --pane "$cpane" --timeout 120000 -- -s read-only -a never \
  "Remember the code word OTTER. Reply only OK." >/dev/null 2>&1 || true
h agent wait "$run-cx" --until "done" --until idle --timeout 120000 >/dev/null
csid=$(sid_of "$run-cx")
[[ -n "$csid" && "$csid" != null ]] || fail "herdr reports no session id for the codex agent"
echo "setup: codex agent $run-cx in $cpane, session $csid"

if [[ -n $oc_ready ]]; then
  OPENCODE_CONFIG_DIR="$dir/opencode" "$tools" agent start "$run-oc" --kind opencode --agent "$oc_agent" --cwd "$dir" ||
    fail "agent start of the opencode agent exited $?"
  prompt_to "$run-oc" "Remember the code word LYNX. Reply only OK."
  h agent wait "$run-oc" --until idle --until "done" --timeout 180000 >/dev/null
  osid=$(sid_of "$run-oc")
  opane=$(h agent get "$run-oc" | jq -r .result.agent.pane_id)
  [[ -n "$osid" && "$osid" != null ]] || fail "herdr reports no session id for the opencode agent"
  echo "setup: opencode agent $run-oc in $opane, session $osid"
fi

rm -f "$state/switched.json"
cls scan || fail "scan before the server stop exited $?"
key="pane-$(tr ':' '-' <<<"$upane" | tr '[:upper:]' '[:lower:]')"
jq -e --arg k "$key" --arg s "$usid" '.agents[$k] | .session == $s and .rotate and .named == false and (.model | test("haiku"))' \
  "$state/agents.json" >/dev/null || fail "scan did not record the unnamed agent as $key: $(jq -c --arg k "$key" '.agents[$k]' "$state/agents.json")"
jq -e --arg n "$run-cx" --arg s "$csid" '.agents[$n] | .kind == "codex" and .session == $s' "$state/agents.json" >/dev/null ||
  fail "scan did not record the codex agent: $(jq -c --arg n "$run-cx" '.agents[$n]' "$state/agents.json")"
[[ -z $oc_ready ]] || jq -e --arg n "$run-oc" --arg d "$dir/opencode" '.agents[$n].opencode_config.OPENCODE_CONFIG_DIR == $d' \
  "$state/agents.json" >/dev/null || fail "scan did not record the config folder of the opencode agent"

h server stop >/dev/null
for _ in $(seq 30); do
  [[ -z "$(claude_in "$pane")$(claude_in "$upane")" ]] && break
  sleep 1
done
[[ -z "$(claude_in "$pane")$(claude_in "$upane")" ]] || fail "claude outlived the stopped server"
cls scan || fail "scan after the server stop exited $?"
[[ "$(account "$pane")" == "$first" ]] || fail "restore put the agent on $(account "$pane"), not $first"
check_agent restore
echo "restore: back in $pane on $first"

h agent wait "$upane" --until idle --until "done" --timeout 180000 >/dev/null
[[ "$(name_of "$upane")" == null ]] || fail "restore left the unnamed agent with the name $(name_of "$upane")"
[[ "$(sid_of "$upane")" == "$usid" ]] || fail "restore changed the session of the unnamed agent"
[[ "$(account "$upane")" == "$uaccount" ]] || fail "restore put the unnamed agent on $(account "$upane"), not $uaccount"
upid=$(claude_in "$upane" | cut -f3)
grep -qx 'CLAUDE_TOOLS_ROTATE_ID=[0-9]*' <(tr '\0' '\n' <"/proc/$upid/environ") || fail "restore did not start the unnamed agent through rotate"
ucmd=$(claude_in "$upane" | cut -f2)
grep -q -- "--model claude-haiku" <<<"$ucmd" || fail "restore did not pin the transcript model: $ucmd"
grep -q -- "--dangerously-skip-permissions" <<<"$ucmd" || fail "restore dropped the unnamed agent's own flag: $ucmd"
said_in "$usid" '.[] | select(.type == "user") | .message.content | if type == "string" then . else (.[]?.text? // empty) end' \
  -F "The herdr server restarted, so every process this session started has ended" ||
  fail "the unnamed agent did not get the restart message"
prompt_to "$upane" "What was the code word I gave you? Reply with only the code word followed directly by the digit 7, no space."
said_in "$usid" "$last_reply" -i heron7 || fail "the unnamed agent lost its code word after the restore"
echo "restore: unnamed agent back in $upane on $uaccount through rotate with $(grep -o -- '--model [^ ]*' <<<"$ucmd")"
workspaces=$(h workspace list | jq '.result.workspaces | length')
cls resume "$key" || fail "resume of the running unnamed agent exited $?"
grep -q "$key is running already in pane $upane" "$state/events.log" || fail "resume did not find the running unnamed agent $key"
(($(h workspace list | jq '.result.workspaces | length') == workspaces)) || fail "resume of the running unnamed agent opened a workspace"
echo "resume: the running unnamed agent $key stays the only copy"

h agent wait "$run-cx" --until idle --until "done" --timeout 180000 >/dev/null
[[ "$(sid_of "$run-cx")" == "$csid" ]] || fail "restore changed the codex session"
cpid=$(proc_in "$cpane" 'codex|\.codex-wrapped')
[[ -n "$cpid" ]] || fail "restore started no codex in $cpane"
ccmd=$(tr '\0' ' ' <"/proc/$cpid/cmdline")
grep -q -- "resume $csid -s read-only -a never *$" <<<"$ccmd" ||
  fail "restore did not start codex as resume $csid with its options and without its first prompt: $ccmd"
prompt_to "$run-cx" "What was the code word I gave you? Reply with only the code word followed directly by the digit 7, no space."
h agent wait "$run-cx" --until idle --until "done" --timeout 120000 >/dev/null
h agent read "$run-cx" --source recent-unwrapped --lines 40 | grep -qi otter7 || fail "the codex agent lost its code word after the restore"
echo "restore: codex agent back in $cpane on session $csid"

if [[ -n $oc_ready ]]; then
  h agent wait "$run-oc" --until idle --until "done" --timeout 180000 >/dev/null
  [[ "$(sid_of "$run-oc")" == "$osid" ]] || fail "restore changed the opencode session"
  opid=$(proc_in "$opane" 'opencode|\.opencode2-wrap')
  [[ -n "$opid" ]] || fail "restore started no opencode in $opane"
  grep -qxF "OPENCODE_CONFIG_CONTENT={\"default_agent\": \"$oc_agent\"}" <(tr '\0' '\n' <"/proc/$opid/environ") ||
    fail "restore did not start opencode in its agent $oc_agent"
  grep -qxF "OPENCODE_CONFIG_DIR=$dir/opencode" <(tr '\0' '\n' <"/proc/$opid/environ") ||
    fail "restore did not give opencode the config folder it ran with, although the scanner lacks it"
  prompt_to "$run-oc" "What was the code word I gave you? Reply with only the code word followed directly by the digit 7, no space."
  h agent wait "$run-oc" --until idle --until "done" --timeout 180000 >/dev/null
  h agent read "$run-oc" --source recent-unwrapped --lines 40 | grep -qi lynx7 || fail "the opencode agent lost its code word after the restore"
  echo "restore: opencode agent back in $opane on session $osid"
else
  echo "restore of an opencode agent: skipped, opencode or its config is missing on this host"
fi
for target in "$upane" "$run-cx" ${oc_ready:+"$run-oc"}; do
  h agent send-keys "$target" ctrl+c >/dev/null 2>&1 || true
done
h agent prompt "$upane" /exit >/dev/null 2>&1 || true

[[ $mode == settings ]] || ask "Delete every scheduled job with CronDelete. Reply only OK."
h agent prompt "$name" /exit >/dev/null
for ((attempt = 0; attempt < 30; attempt++)); do
  if [[ -z "$(claude_in "$pane")" ]] && h agent list |
    jq -e --arg n "$name" 'all(.result.agents[]; .name != $n)' >/dev/null; then
    break
  fi
  sleep 1
done
((attempt < 30)) || fail "Claude did not exit and leave the herdr agent list within 30 s"
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
  env=$(tr '\0' '\n' 2>/dev/null <"/proc/$p/environ") || continue
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
if foreign_available; then
  foreign="$run-foreign"
  start_foreign_agent "$foreign" "$dir"
  cls scan || fail "scan with an agent of another user exited $?"
  [[ "$(foreign_pids)" == "$foreign_start_pids" ]] || fail "scan changed the claude processes of sl-factory"
  grep -q "$foreign" "$state/events.log" 2>/dev/null && fail "scan logged the agent of another user: $(grep "$foreign" "$state/events.log")"
  jq -e --arg n "$foreign" '(.agents | has($n) | not) and (.ended | has($n) | not)' "$state/agents.json" >/dev/null ||
    fail "the record holds the agent of another user: $(jq -c . "$state/agents.json")"
  cls resume "$foreign" || fail "resume of an agent of another user exited $?"
  [[ "$(foreign_pids)" == "$foreign_start_pids" ]] || fail "resume restarted the agent of another user"
  out=$(cls switch "$foreign" 2>&1) && fail "switch of an agent of another user exited 0"
  [[ "$(foreign_pids)" == "$foreign_start_pids" ]] || fail "switch restarted the agent of another user: $out"
  echo "agent of another user: scan, resume and switch leave it running and unrecorded"
else
  echo "agent of another user: skipped, sl-factory has no account folder or omer cannot sudo to it on this host"
fi
ok=1
echo PASS
