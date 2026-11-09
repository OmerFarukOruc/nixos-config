#!/usr/bin/env bash
set -euo pipefail
tools="$(readlink -f "${1:?usage: $0 BIN-DIR}")/claude-tools"
dir=$(mktemp -d /tmp/agent-e2e.XXXXXX)
run="agent-e2e-$(basename "$dir" | cut -d. -f2 | tr '[:upper:]' '[:lower:]')"
real_herdr="$(command -v herdr)"
export CLAUDE_TOOLS_HERDR_SESSION="$run" CLAUDE_TOOLS_STATE="$dir/state"
name="$run-a"
foreign="$run-foreign"
work="$dir/work"
watch_pid=""
mkdir -p "$work"
h() { "$real_herdr" --session "$run" "$@"; }

stop_watch() {
  if [[ -n "$watch_pid" ]] && ps -p "$watch_pid" >/dev/null 2>&1; then
    kill "$watch_pid"
    wait "$watch_pid" 2>/dev/null || true
    echo "--- agent watch output"
    cat "$dir/watch.log"
  fi
  watch_pid=""
}
cleanup() {
  stop_watch
  "$tools" agent stop --force "$name" >/dev/null 2>&1 || true
  "$tools" agent stop --force "$foreign" >/dev/null 2>&1 || true
  h server stop >/dev/null 2>&1 || true
  sleep 2
  "$real_herdr" session delete "$run" >/dev/null 2>&1 || true
}
trap cleanup EXIT
source "$(dirname "$0")/foreign-agent.sh"
fail() {
  echo "FAIL: $*"
  pane=$(h agent get "$name" 2>/dev/null | jq -r '.result.agent.pane_id // empty') || true
  [[ -n "$pane" ]] && {
    echo "--- pane $pane"
    h pane read "$pane" 2>&1 | tail -n 40
  }
  [[ -f "$dir/watch.log" ]] && {
    echo "--- agent watch output"
    cat "$dir/watch.log"
  }
  exit 1
}
step() { echo "step $1: $2"; }
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
agent_gone() { ! agent_listed "$1"; }
agent_pane() { h agent get "$name" | jq -r '.result.agent.pane_id'; }
pane_moved() { [[ "$(agent_pane)" != "$1" ]]; }
pane_has_no_agent() { [[ "$(h pane get "$1" | jq -r '.result.pane.agent // "none"')" == none ]]; }
watch_matches() { grep -qE -- "$1" "$dir/watch.log"; }
lines_of() { grep -c -- "$1" "$dir/watch.log" || true; }
more_lines() { [[ "$(lines_of "$1")" -gt "$2" ]]; }
start_watch() {
  : >"$dir/watch.log"
  "$tools" agent watch "$name" >"$dir/watch.log" 2>&1 &
  watch_pid=$!
  wait_for 15 watch_matches "watching herdr agents named" || fail "the watcher did not start"
}

"$tools" limit-switch restore || fail "restore could not start the $run server"
h workspace create --cwd "$dir" --label "$run" --no-focus >/dev/null
account=$("$tools" usage --order | head -n 1)
[[ -n "$account" ]] || fail "claude-tools usage --order names no account to start the agent on"

step 1 "a watcher started before the agent sees it appear and sees its first turn finish"
start_watch
cat >"$dir/brief.md" <<EOF
Reply with one line only: STATUS: brief done
EOF
(cd "$dir" && "$tools" agent start "$name" --account "$account" --cwd work --model sonnet --brief "$dir/brief.md") || fail "agent start exited $?"
[[ "$(tab_count "$name")" == 1 ]] || fail "wanted one tab named $name"
pane_cwd=$(h pane get "$(agent_pane)" | jq -r '.result.pane.cwd')
[[ "$pane_cwd" == "$(readlink -f "$work")" ]] || fail "the relative --cwd started the pane in $pane_cwd, wanted $work"
wait_for 30 watch_matches "$name appeared" || fail "the watcher did not see $name appear"
h agent wait "$name" --until idle --until "done" --timeout 120000 >/dev/null || fail "the agent did not settle after its brief"
sleep 3
before=$(lines_of "$name finished a turn")
h agent prompt "$name" "Reply with exactly one line: STATUS: first turn" >/dev/null
wait_for 150 more_lines "$name finished a turn" "$before" || fail "the watcher did not see the first turn finish"

step 2 "an agent waiting at a question prints BLOCKED"
blocked=$(lines_of "$name BLOCKED at a question or approval")
h agent prompt "$name" "Use the AskUserQuestion tool to ask me one question, 'Continue?', with the options Yes and No. Do nothing else." >/dev/null
wait_for 150 more_lines "$name BLOCKED at a question or approval" "$blocked" || fail "no BLOCKED line for the open question"
rc=0
err=$("$tools" agent stop "$name" 2>&1) || rc=$?
[[ "$rc" == 1 ]] || fail "agent stop of a blocked agent exited $rc, wanted 1"
grep -q "is blocked" <<<"$err" || fail "no 'is blocked' in: $err"
agent_listed "$name" || fail "the refused agent stop removed the blocked agent"
finished=$(lines_of "$name finished a turn")
h agent send-keys "$name" esc >/dev/null
h agent wait "$name" --until idle --until "done" --timeout 60000 >/dev/null || fail "the agent did not settle after the question was dismissed"
wait_for 15 more_lines "$name finished a turn" "$finished" || fail "no finished line after the question was dismissed"

step 3 "after its pane moves to another workspace, the watcher still sees the next turn finish"
old_pane=$(agent_pane)
h pane move "$old_pane" --new-workspace --label "$run-moved" --tab-label "$name" --no-focus >/dev/null
wait_for 15 pane_moved "$old_pane" || fail "the pane id did not change after the move"
before=$(lines_of "$name finished a turn")
h agent prompt "$name" "Run 'sleep 5' with the Bash tool, then reply with exactly one line: STATUS: after move" >/dev/null
wait_for 150 more_lines "$name finished a turn" "$before" || fail "no finished line for the turn after the move"

step 4 "a restarted watcher prints done for an agent that finished a turn it missed"
stop_watch
h agent prompt "$name" "Reply with exactly one line: STATUS: while no watcher" --wait --timeout 150000 >/dev/null || fail "the turn without a watcher did not settle"
start_watch
wait_for 15 watch_matches "$name is done" || fail "the restarted watcher did not print done for the missed turn"

step 5 "a running name is refused and adds no tab"
rc=0
err=$("$tools" agent start "$name" --account "$account" --cwd "$work" 2>&1) || rc=$?
[[ "$rc" == 1 ]] || fail "the second agent start exited $rc, wanted 1"
grep -q "already running" <<<"$err" || fail "no 'already running' in: $err"
[[ "$(tab_count "$name")" == 1 ]] || fail "the refused start changed the tabs"

step 6 "agent stop refuses a working agent and leaves it running"
h agent prompt "$name" "Run the command python3 -c 'import time; time.sleep(60)' with the Bash tool in the foreground, without run_in_background, then reply with exactly one line: STATUS: slept" >/dev/null
h agent wait "$name" --until working --timeout 30000 >/dev/null || fail "the agent did not start working"
rc=0
err=$("$tools" agent stop "$name" 2>&1) || rc=$?
[[ "$rc" == 1 ]] || fail "agent stop of a working agent exited $rc, wanted 1"
grep -q "is working" <<<"$err" || fail "no 'is working' in: $err"
agent_listed "$name" || fail "the refused agent stop removed the working agent"
h agent wait "$name" --until idle --until "done" --timeout 120000 >/dev/null || fail "the agent did not settle after the refused stop"

step 7 "agent stop removes the agent and its tab, and the watcher says it left; the name starts again and --force stops it while it works"
"$tools" agent stop "$name" || fail "agent stop exited $?"
agent_listed "$name" && fail "the agent is still listed after agent stop"
tab_labelled "$name" && fail "the tab is still open after agent stop"
wait_for 15 watch_matches "$name ALERT left the agent list" || fail "the watcher did not say $name left"
"$tools" agent start "$name" --account "$account" --cwd "$work" --model sonnet || fail "the name could not start again"
h agent prompt "$name" "Run the command python3 -c 'import time; time.sleep(60)' with the Bash tool in the foreground, without run_in_background, then reply with exactly one line: STATUS: slept" >/dev/null
h agent wait "$name" --until working --timeout 30000 >/dev/null || fail "the restarted agent did not start working"
rc=0
err=$("$tools" agent stop "$name" 2>&1) || rc=$?
[[ "$rc" == 1 ]] || fail "the plain stop before --force exited $rc, wanted 1"
grep -q "is working" <<<"$err" || fail "the plain stop before --force did not refuse a working agent: $err"
"$tools" agent stop --force "$name" || fail "agent stop --force of a working agent exited $?"
agent_listed "$name" && fail "the agent is still listed after agent stop --force"
tab_labelled "$name" && fail "the second tab is still open"

step 8 "an agent whose claude exited on its own: agent stop still closes its tab"
"$tools" agent start "$name" --account "$account" --cwd "$work" --model sonnet || fail "the name could not start a third time"
pane=$(agent_pane)
h agent prompt "$name" "/exit" >/dev/null
wait_for 60 pane_has_no_agent "$pane" || fail "claude did not exit after /exit"
[[ "$(tab_count "$name")" == 1 ]] || fail "the tab went away with claude, so there is nothing to clean up"
"$tools" agent stop "$name" || fail "agent stop of an exited agent exited $?"
agent_listed "$name" && fail "the agent is listed after agent stop"
tab_labelled "$name" && fail "the tab of the exited agent is still open"

step 9 "closing a live agent's tab prints that it left"
appeared=$(lines_of "$name appeared")
"$tools" agent start "$name" --account "$account" --cwd "$work" --model sonnet || fail "the name could not start a fourth time"
wait_for 30 more_lines "$name appeared" "$appeared" || fail "the watcher did not see the fourth start"
left=$(lines_of "$name ALERT left the agent list")
h tab close "$(h agent get "$name" | jq -r '.result.agent.tab_id')" >/dev/null
wait_for 15 more_lines "$name ALERT left the agent list" "$left" || fail "no left line after the tab closed"

step 10 "a watcher whose herdr server stops says so, follows the restarted server, and sees the next turn"
h server stop >/dev/null
wait_for 30 watch_matches "ALERT watcher cannot follow herdr" || fail "no ALERT after the server stopped"
ps -p "$watch_pid" >/dev/null || fail "the watcher exited when the server stopped"
"$tools" limit-switch restore || fail "restore could not start the $run server again"
h workspace create --cwd "$dir" --label "$run" --no-focus >/dev/null
before=$(lines_of "$name finished a turn")
"$tools" agent start "$name" --account "$account" --cwd "$work" --model sonnet --brief "$dir/brief.md" || fail "the name could not start on the restarted server"
wait_for 30 watch_matches "watcher follows herdr again" || fail "the watcher did not follow the restarted server"
wait_for 150 more_lines "$name finished a turn" "$before" || fail "no finished line on the restarted server"

if foreign_available; then
  step 11 "agent stop ends an agent that runs as another user, though its environment is unreadable"
  start_foreign_agent "$foreign" "$dir"
  [[ -n "$(foreign_pids)" ]] || fail "no claude process of sl-factory runs"
  "$tools" agent stop --force "$foreign" || fail "agent stop of an agent of another user exited $?"
  wait_for 15 agent_gone "$foreign" || fail "the agent of another user is still listed after agent stop"
  [[ -z "$(foreign_pids)" ]] || fail "a claude process of sl-factory survived agent stop"
else
  echo "step 11: skipped, sl-factory has no account folder or omer cannot sudo to it on this host"
fi

echo PASS
