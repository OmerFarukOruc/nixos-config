#!/usr/bin/env bash
set -euo pipefail
tools="$(readlink -f "${1:?usage: $0 BIN-DIR}")/claude-tools"
dir=$(mktemp -d /tmp/orch-e2e.XXXXXX)
run="orch-e2e-$(basename "$dir" | cut -d. -f2 | tr '[:upper:]' '[:lower:]')"
real_herdr="$(command -v herdr)"
export CLAUDE_TOOLS_HERDR_SESSION="$run" CLAUDE_TOOLS_STATE="$dir/state" CLAUDE_TOOLS_INBOX="$dir/inbox/inbox.log"
name="$run-a"
work="$dir/work"
watch_pid=""
mkdir -p "$work"
h() { "$real_herdr" --session "$run" "$@"; }

stop_watch() {
  if [[ -n "$watch_pid" ]] && ps -p "$watch_pid" >/dev/null 2>&1; then
    kill "$watch_pid"
    wait "$watch_pid" 2>/dev/null || true
    echo "--- orch watch output"
    cat "$dir/watch.log"
  fi
  watch_pid=""
}
cleanup() {
  stop_watch
  "$tools" agent stop "$name" >/dev/null 2>&1 || true
  h server stop >/dev/null 2>&1 || true
  sleep 2
  "$real_herdr" session delete "$run" >/dev/null 2>&1 || true
}
trap cleanup EXIT
fail() {
  echo "FAIL: $*"
  pane=$(h agent get "$name" 2>/dev/null | jq -r '.result.agent.pane_id // empty') || true
  [[ -n "$pane" ]] && {
    echo "--- pane $pane"
    h pane read "$pane" 2>&1 | tail -n 40
  }
  [[ -f "$dir/watch.log" ]] && {
    echo "--- orch watch output"
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
pane_has_no_agent() { [[ "$(h pane get "$1" | jq -r '.result.pane.agent // "none"')" == none ]]; }
inbox_has() { grep -qP "$1" "$CLAUDE_TOOLS_INBOX" 2>/dev/null; }
watch_has() { grep -qF -- "$1" "$dir/watch.log"; }
watch_matches() { grep -qE -- "$1" "$dir/watch.log"; }
start_watch() {
  : >"$dir/watch.log"
  "$tools" orch watch "$name|driver" >"$dir/watch.log" 2>&1 &
  watch_pid=$!
}

"$tools" limit-switch restore || fail "restore could not start the $run server"
h workspace create --cwd "$dir" --label "$run" --no-focus >/dev/null
account=$("$tools" usage --order | head -n 1)
[[ -n "$account" ]] || fail "claude-tools usage --order names no account to start the agent on"

step 1 "a notice waits in the inbox before any watcher"
"$tools" orch notify INFO "sent before the watcher" --from earlier

step 2 "agent start starts the agent; its brief sends a NEED notice"
cat >"$dir/brief.md" <<EOF
Run this one shell command with the Bash tool, exactly as written:
$tools orch notify NEED "e2e question"
Then reply with one line only: STATUS: brief done
EOF
(cd "$dir" && "$tools" agent start "$name" --account "$account" --cwd work --model sonnet --brief "$dir/brief.md") || fail "agent start exited $?"
[[ "$(tab_count "$name")" == 1 ]] || fail "wanted one tab named $name"
pane_cwd=$(h pane get "$(h agent get "$name" | jq -r '.result.agent.pane_id')" | jq -r '.result.pane.cwd')
[[ "$pane_cwd" == "$(readlink -f "$work")" ]] || fail "the relative --cwd started the pane in $pane_cwd, wanted $work"
wait_for 120 inbox_has "\\t$name\\tNEED\\te2e question\$" || fail "no NEED notice from $name in the inbox"
h agent wait "$name" --until idle --until "done" --timeout 120000 >/dev/null || fail "the agent did not settle after its brief"

step 3 "a second notice goes in while no watcher runs; the watcher prints all three at start"
"$tools" orch notify DONE "second while no watcher" --from driver
start_watch
wait_for 30 watch_has "driver DONE | second while no watcher" || fail "the notice sent without a watcher was lost"
watch_has "earlier INFO | sent before the watcher" || fail "the notice from before the agent was lost"
watch_has "$name NEED (reply required) | e2e question" || fail "the NEED notice did not print as reply required"

step 4 "a finished turn prints its STATUS line, and agent peek shows it"
sleep 7
h agent prompt "$name" "Run 'sleep 12' with the Bash tool, then reply with exactly one line: STATUS: e2e second turn" >/dev/null
wait_for 150 watch_matches "$name working -> (idle|done) \\| STATUS: e2e second turn" || fail "no finished-turn line with the STATUS"
peek=$("$tools" agent peek "$name") || fail "agent peek exited $?"
grep -qF "status: STATUS: e2e second turn" <<<"$peek" || fail "agent peek did not show the STATUS line: $peek"

step 5 "after a watcher restart only the new notice prints"
stop_watch
start_watch
sleep 7
"$tools" orch notify INFO "third after restart" --from driver
wait_for 30 watch_has "driver INFO | third after restart" || fail "the notice sent after the restart did not print"
for old in "sent before the watcher" "e2e question" "second while no watcher"; do
  watch_has "$old" && fail "the restart printed '$old' again"
done
stop_watch

step 6 "a running name is refused and adds no tab"
rc=0
err=$("$tools" agent start "$name" --account "$account" --cwd "$work" 2>&1) || rc=$?
[[ "$rc" == 1 ]] || fail "the second agent start exited $rc, wanted 1"
grep -q "already running" <<<"$err" || fail "no 'already running' in: $err"
[[ "$(tab_count "$name")" == 1 ]] || fail "the refused start changed the tabs"

step 7 "agent stop removes the agent and its tab; the name starts and stops again at once"
"$tools" agent stop "$name" || fail "agent stop exited $?"
agent_listed "$name" && fail "the agent is still listed after agent stop"
tab_labelled "$name" && fail "the tab is still open after agent stop"
"$tools" agent start "$name" --account "$account" --cwd "$work" --model sonnet || fail "the name could not start again"
"$tools" agent stop "$name" || fail "the second agent stop exited $?"
tab_labelled "$name" && fail "the second tab is still open"

step 8 "an agent whose claude exited on its own: agent stop still closes its tab"
"$tools" agent start "$name" --account "$account" --cwd "$work" --model sonnet || fail "the name could not start a third time"
pane=$(h agent get "$name" | jq -r '.result.agent.pane_id')
h agent prompt "$name" "/exit" >/dev/null
wait_for 60 pane_has_no_agent "$pane" || fail "claude did not exit after /exit"
[[ "$(tab_count "$name")" == 1 ]] || fail "the tab went away with claude, so there is nothing to clean up"
"$tools" agent stop "$name" || fail "agent stop of an exited agent exited $?"
agent_listed "$name" && fail "the agent is listed after agent stop"
tab_labelled "$name" && fail "the tab of the exited agent is still open"

step 9 "a second watcher replaces the first; a lock held by another program refuses a watcher"
lock="$CLAUDE_TOOLS_INBOX.watcher"
lock_names() { [[ "$(cat "$lock" 2>/dev/null)" == "$1" ]]; }
start_watch
first=$watch_pid
wait_for 10 lock_names "$first" || fail "the first watcher did not write its pid to $lock"
"$tools" orch watch "$name|driver" >"$dir/watch2.log" 2>&1 &
watch_pid=$!
wait_for 15 lock_names "$watch_pid" || fail "the second watcher did not take the lock"
wait "$first" || true
grep -qF "watcher stopped by SIGTERM" "$dir/watch.log" || fail "the first watcher did not say it was stopped"
wait_for 10 grep -qF "watcher replaced pid $first" "$dir/watch2.log" || fail "the second watcher did not name pid $first"
stop_watch
(
  exec 9>>"$lock"
  flock 9
  exec sleep 30
) &
holder=$!
wait_for 10 bash -c "! flock -n '$lock' true" || fail "flock did not take $lock"
echo "$holder" >"$lock"
rc=0
out=$(timeout 20 "$tools" orch watch "$name|driver" 2>&1) || rc=$?
kill "$holder"
[[ "$rc" == 1 ]] || fail "a watcher next to a non-watcher lock holder exited $rc, wanted 1: $out"
grep -qF "which is not a watcher" <<<"$out" || fail "no refusal in: $out"

echo PASS
