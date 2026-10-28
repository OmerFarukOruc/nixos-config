#!/usr/bin/env bash
# End-to-end check of agent-start, agent-stop, agent-peek, orch-notify and orch-watch on risoluto-dev-1, with a real
# herdr server and real Claude agents (sonnet). It runs in its own herdr session, orch-e2e-<run>, with its own
# inbox and state folder, so Omer's agents and records stay untouched.
#   1. A notice is already in the inbox before any watcher or agent exists.
#   2. agent-start runs from the folder above the work folder with a relative --cwd,
#      and the pane starts in the work folder. The brief makes the agent run orch-notify NEED, so the notice
#      carries the agent's name, found from its pane, and reaches the inbox through the pane's environment.
#   3. A second notice is sent while no watcher runs; orch-watch then prints all three notices at start.
#   4. A turn of the agent ends; orch-watch prints `working -> idle` (or done) with the agent's STATUS line, and agent-peek
#      shows the same line.
#   5. orch-watch is stopped and started again; a third notice prints and the earlier three do not.
#   6. agent-start of a running name is refused and adds no tab.
#   7. agent-stop removes the agent and its tab; the same name starts and stops again at once.
#   8. An agent whose claude exited on its own (/exit typed to it) leaves a tab with a shell; agent-stop closes it.
# The run costs a few sonnet turns and about 2 minutes.
#   orch-e2e.sh [BIN]    BIN is the folder with the scripts, default: ../bin next to this folder
# Passes when it prints PASS and exits 0; the log shows each step and the output of each orch-watch run.
set -euo pipefail
bin="$(readlink -f "${1:-$(dirname "$0")/../bin}")"
dir=$(mktemp -d /tmp/orch-e2e.XXXXXX)
run="orch-e2e-$(basename "$dir" | cut -d. -f2 | tr '[:upper:]' '[:lower:]')"
real_herdr="$(command -v herdr)"
export CLAUDE_LIMIT_SWITCH_SESSION="$run" CLAUDE_LIMIT_SWITCH_STATE="$dir/state" ORCH_INBOX="$dir/inbox/inbox.log"
name="$run-a"
work="$dir/work"
watch_pid=""
mkdir -p "$work"
h() { "$real_herdr" --session "$run" "$@"; }

stop_watch() {
  if [[ -n "$watch_pid" ]] && ps -p "$watch_pid" >/dev/null 2>&1; then
    kill "$watch_pid"
    wait "$watch_pid" 2>/dev/null || true
    echo "--- orch-watch output"
    cat "$dir/watch.log"
  fi
  watch_pid=""
}
cleanup() {
  stop_watch
  "$bin/agent-stop" "$name" >/dev/null 2>&1 || true
  h server stop >/dev/null 2>&1 || true
  sleep 2
  "$real_herdr" session delete "$run" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() {
  echo "FAIL: $*"
  [[ -f "$dir/watch.log" ]] && {
    echo "--- orch-watch output"
    cat "$dir/watch.log"
  }
  exit 1
}
step() { echo "step $1: $2"; }
# wait_for SECONDS COMMAND...: runs the command once a second until it succeeds
wait_for() {
  local n=$1
  shift
  for _ in $(seq "$n"); do
    "$@" && return 0
    sleep 1
  done
  return 1
}
tab_labelled() { h tab list | jq -e --arg n "$1" '[.result.tabs[] | select(.label == $n)] | length > 0' >/dev/null; }
tab_count() { h tab list | jq --arg n "$1" '[.result.tabs[] | select(.label == $n)] | length'; }
agent_listed() { h agent get "$1" 2>/dev/null | jq -e '.result.agent' >/dev/null; }
# true once no agent runs in pane $1, which is when claude has exited and a shell is left
pane_has_no_agent() { [[ "$(h pane get "$1" | jq -r '.result.pane.agent // "none"')" == none ]]; }
inbox_has() { grep -qP "$1" "$ORCH_INBOX" 2>/dev/null; }
watch_has() { grep -qF -- "$1" "$dir/watch.log"; }
watch_matches() { grep -qE -- "$1" "$dir/watch.log"; }
start_watch() {
  : >"$dir/watch.log"
  "$bin/orch-watch" "$name|driver" >"$dir/watch.log" 2>&1 &
  watch_pid=$!
}

"$bin/claude-limit-switch" restore || fail "restore could not start the $run server"
h workspace create --cwd "$dir" --label "$run" --no-focus >/dev/null

step 1 "a notice waits in the inbox before any watcher"
"$bin/orch-notify" INFO "sent before the watcher" --from earlier

step 2 "agent-start starts the agent; its brief sends a NEED notice"
cat >"$dir/brief.md" <<EOF
Run this one shell command with the Bash tool, exactly as written:
$bin/orch-notify NEED "e2e question"
Then reply with one line only: STATUS: brief done
EOF
(cd "$dir" && "$bin/agent-start" "$name" --cwd work --model sonnet --brief "$dir/brief.md") || fail "agent-start exited $?"
[[ "$(tab_count "$name")" == 1 ]] || fail "wanted one tab named $name"
pane_cwd=$(h pane get "$(h agent get "$name" | jq -r '.result.agent.pane_id')" | jq -r '.result.pane.cwd')
[[ "$pane_cwd" == "$(readlink -f "$work")" ]] || fail "the relative --cwd started the pane in $pane_cwd, wanted $work"
wait_for 120 inbox_has "\\t$name\\tNEED\\te2e question\$" || fail "no NEED notice from $name in the inbox"
h agent wait "$name" --until idle --until "done" --timeout 120000 >/dev/null || fail "the agent did not settle after its brief"

step 3 "a second notice goes in while no watcher runs; the watcher prints all three at start"
"$bin/orch-notify" DONE "second while no watcher" --from driver
start_watch
wait_for 30 watch_has "driver DONE | second while no watcher" || fail "the notice sent without a watcher was lost"
watch_has "earlier INFO | sent before the watcher" || fail "the notice from before the agent was lost"
watch_has "$name NEED (reply required) | e2e question" || fail "the NEED notice did not print as reply required"

step 4 "a finished turn prints its STATUS line, and agent-peek shows it"
sleep 7
h agent prompt "$name" "Run 'sleep 12' with the Bash tool, then reply with exactly one line: STATUS: e2e second turn" >/dev/null
wait_for 150 watch_matches "$name working -> (idle|done) \\| STATUS: e2e second turn" || fail "no finished-turn line with the STATUS"
peek=$("$bin/agent-peek" "$name") || fail "agent-peek exited $?"
grep -qF "status: STATUS: e2e second turn" <<<"$peek" || fail "agent-peek did not show the STATUS line: $peek"

step 5 "after a watcher restart only the new notice prints"
stop_watch
start_watch
sleep 7
"$bin/orch-notify" INFO "third after restart" --from driver
wait_for 30 watch_has "driver INFO | third after restart" || fail "the notice sent after the restart did not print"
for old in "sent before the watcher" "e2e question" "second while no watcher"; do
  watch_has "$old" && fail "the restart printed '$old' again"
done
stop_watch

step 6 "a running name is refused and adds no tab"
rc=0
err=$("$bin/agent-start" "$name" --cwd "$work" 2>&1) || rc=$?
[[ "$rc" == 1 ]] || fail "the second agent-start exited $rc, wanted 1"
grep -q "already running" <<<"$err" || fail "no 'already running' in: $err"
[[ "$(tab_count "$name")" == 1 ]] || fail "the refused start changed the tabs"

step 7 "agent-stop removes the agent and its tab; the name starts and stops again at once"
"$bin/agent-stop" "$name" || fail "agent-stop exited $?"
agent_listed "$name" && fail "the agent is still listed after agent-stop"
tab_labelled "$name" && fail "the tab is still open after agent-stop"
"$bin/agent-start" "$name" --cwd "$work" --model sonnet || fail "the name could not start again"
"$bin/agent-stop" "$name" || fail "the second agent-stop exited $?"
tab_labelled "$name" && fail "the second tab is still open"

step 8 "an agent whose claude exited on its own: agent-stop still closes its tab"
"$bin/agent-start" "$name" --cwd "$work" --model sonnet || fail "the name could not start a third time"
pane=$(h agent get "$name" | jq -r '.result.agent.pane_id')
h agent prompt "$name" "/exit" >/dev/null
wait_for 60 pane_has_no_agent "$pane" || fail "claude did not exit after /exit"
[[ "$(tab_count "$name")" == 1 ]] || fail "the tab went away with claude, so there is nothing to clean up"
"$bin/agent-stop" "$name" || fail "agent-stop of an exited agent exited $?"
agent_listed "$name" && fail "the agent is listed after agent-stop"
tab_labelled "$name" && fail "the tab of the exited agent is still open"

echo PASS
