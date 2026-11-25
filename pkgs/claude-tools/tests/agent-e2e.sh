#!/usr/bin/env bash
set -euo pipefail
tools="$(readlink -f "${1:?usage: $0 BIN-DIR}")/claude-tools"
dir=$(mktemp -d /tmp/agent-e2e.XXXXXX)
run="agent-e2e-$(basename "$dir" | cut -d. -f2 | tr '[:upper:]' '[:lower:]')"
real_herdr="$(command -v herdr)"
export CLAUDE_TOOLS_HERDR_SESSION="$run" CLAUDE_TOOLS_STATE="$dir/state"
name="$run-a"
foreign="$run-foreign"
slow="$run-slow"
oc="$run-oc"
cx="$run-cx"
work="$dir/work"
watch_pid=""
watch_deadline_s=3600
mkdir -p "$work"
h() { "$real_herdr" --session "$run" "$@"; }

show_watch() {
  if [[ -f "$dir/watch.log" ]]; then
    echo "--- agent watch output"
    cat "$dir/watch.log"
  fi
}
cleanup() {
  show_watch
  "$tools" agent stop --force "$name" >/dev/null 2>&1 || true
  "$tools" agent stop --force "$foreign" >/dev/null 2>&1 || true
  "$tools" agent stop --force "$slow" >/dev/null 2>&1 || true
  "$tools" agent stop --force "$oc" >/dev/null 2>&1 || true
  "$tools" agent stop --force "$cx" >/dev/null 2>&1 || true
  for i in 1 2 3; do "$tools" agent stop --force "$run-p$i" >/dev/null 2>&1 || true; done
  h server stop >/dev/null 2>&1 || true
  sleep 2
  "$real_herdr" session delete "$run" >/dev/null 2>&1 || true
}
trap cleanup EXIT
source "$(dirname "$0")/foreign-agent.sh"
source "$(dirname "$0")/idle-account.sh"
fail() {
  echo "FAIL: $*"
  pane=$(h agent get "$name" 2>/dev/null | jq -r '.result.agent.pane_id // empty') || true
  [[ -n "$pane" ]] && {
    echo "--- pane $pane"
    h pane read "$pane" 2>&1 | tail -n 40
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
brief_answered() { h agent read "$name" --source recent-unwrapped | grep -q "STATUS: brief 42"; }
more_lines() { [[ "$(lines_of "$1")" -gt "$2" ]]; }
start_watch() {
  timeout "$watch_deadline_s" "$tools" agent watch "$name" >"$dir/watch.log" 2>&1 &
  watch_pid=$!
  wait_for 15 watch_matches "watching herdr agents named" || fail "the watcher did not start"
}

caller_shell=${SHELL:?}
cat >"$dir/slow-prompt.rc" <<'EOF2'
PROMPT_COMMAND='sleep 5'
EOF2
cat >"$dir/shell" <<EOF2
#!/bin/sh
[ -e "$dir/slow-prompt" ] && exec bash --rcfile "$dir/slow-prompt.rc" -i "\$@"
exec "$caller_shell" "\$@"
EOF2
chmod +x "$dir/shell"
oc_agent=e2e-review
oc_ready=""
if command -v opencode >/dev/null && [[ -d "$HOME/.config/opencode" ]]; then
  oc_files="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../agents/opencode/agents" && pwd)"
  for made in "$oc_agent" e2e-no-model; do
    [[ ! -e "$oc_files/$made.md" ]] || fail "the checkout has an agent file $made.md, the name of an agent this test writes"
  done
  mkdir -p "$dir/opencode/agents"
  for entry in "$HOME/.config/opencode"/*; do
    [[ "$(basename "$entry")" == agents ]] || ln -s "$entry" "$dir/opencode/"
  done
  ln -s "$oc_files"/*.md "$dir/opencode/agents/"
  export OPENCODE_CONFIG_DIR="$dir/opencode"
  (cd "$dir" && opencode models --standalone) >"$dir/opencode-models" || fail "opencode models exited $?"
  oc_model=$(grep -m 1 -v -E '[[:space:]|&\\]' "$dir/opencode-models" || true)
  [[ -n "$oc_model" ]] || fail "opencode models lists no model"
  sed "s|^model: .*|model: $oc_model|" "$oc_files/opencode-review.md" >"$dir/opencode/agents/$oc_agent.md"
  sed 's|^model: .*|model: e2e/no-such-model|' "$oc_files/opencode-review.md" >"$dir/opencode/agents/e2e-no-model.md"
  oc_ready=1
fi
codex_ready=""
codex_src="${CODEX_HOME:-$HOME/.codex}"
if command -v codex >/dev/null && [[ -s "$codex_src/auth.json" && -s "$codex_src/models_cache.json" ]]; then
  mkdir -p "$dir/codex"
  ln -s "$codex_src/auth.json" "$codex_src/models_cache.json" "$dir/codex/"
  read -r codex_model codex_effort < <(jq -r '[.models[] | select(.visibility == "list")][0] | "\(.slug) \(.supported_reasoning_levels[0].effort)"' "$codex_src/models_cache.json")
  [[ -n "$codex_model" && "$codex_model" != null && -n "$codex_effort" ]] || fail "$codex_src/models_cache.json lists no codex model with an effort"
  codex_ready=1
fi
export SHELL="$dir/shell"

"$tools" limit-switch restore || fail "restore could not start the $run server"
h workspace create --cwd "$dir" --label "$run" --no-focus >/dev/null
account=$("$tools" usage --order | head -n 1)
[[ -n "$account" ]] || fail "claude-tools usage --order names no account to start the agent on"

step 1 "a watcher started before the agent sees it appear and sees its first turn finish"
start_watch
cat >"$dir/brief.md" <<EOF
Reply with one line only: the text "STATUS: brief " followed by the product of 6 and 7.
EOF
(cd "$dir" && "$tools" agent start "$name" --account "$account" --cwd work --model sonnet --brief "$dir/brief.md") || fail "agent start exited $?"
[[ "$(tab_count "$name")" == 1 ]] || fail "wanted one tab named $name"
pane_cwd=$(h pane get "$(agent_pane)" | jq -r '.result.pane.cwd')
[[ "$pane_cwd" == "$(readlink -f "$work")" ]] || fail "the relative --cwd started the pane in $pane_cwd, wanted $work"
wait_for 30 watch_matches "$name appeared" || fail "the watcher did not see $name appear"
wait_for 120 brief_answered || fail "the agent did not answer its brief"
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

step 4 "a watcher started after an agent finished a turn prints done for it"
h agent prompt "$name" "Reply with exactly one line: STATUS: while no new watcher" --wait --timeout 150000 >/dev/null || fail "the turn without a new watcher did not settle"
timeout 15 "$tools" agent watch "$name" >"$dir/watch-late.log" 2>&1 &
late_pid=$!
rc=0
wait "$late_pid" || rc=$?
[[ "$rc" == 124 ]] || fail "the late watcher exited $rc, wanted 124 from its deadline: $(cat "$dir/watch-late.log")"
grep -q "$name is done" "$dir/watch-late.log" || fail "the late watcher did not print done for the finished turn: $(cat "$dir/watch-late.log")"

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

step 11 "agent start waits for a shell whose every prompt takes 5 s"
touch "$dir/slow-prompt"
"$tools" agent start "$slow" --account "$account" --cwd "$work" --model sonnet || fail "agent start in a slow shell exited $?"
rm "$dir/slow-prompt"
"$tools" agent stop --force "$slow" || fail "agent stop of the agent in a slow shell exited $?"

if foreign_available; then
  step 12 "agent stop ends an agent that runs as another user, though its environment is unreadable"
  start_foreign_agent "$foreign" "$dir"
  "$tools" agent stop --force "$foreign" || fail "agent stop of an agent of another user exited $?"
  wait_for 15 agent_gone "$foreign" || fail "the agent of another user is still listed after agent stop"
  [[ -z "$(foreign_pids)" ]] || fail "a claude process of sl-factory survived agent stop"
else
  echo "step 12: skipped, sl-factory has no account folder or omer cannot sudo to it on this host"
fi

refused() {
  local label=$1 reason=$2 rc=0
  shift 2
  "$tools" agent start "$oc" "$@" >/dev/null 2>"$dir/refused.err" || rc=$?
  [[ "$rc" == 1 ]] || fail "agent start $label exited $rc, wanted 1"
  grep -qF -- "$reason" "$dir/refused.err" || fail "agent start $label failed for another reason: $(cat "$dir/refused.err")"
  tab_labelled "$oc" && fail "agent start $label left a tab"
  return 0
}
if [[ -n "$oc_ready" ]]; then
  step 13 "opencode lists the checkout's agents; an opencode agent starts in its agent and stops; a wrong --agent, an unreachable model, a Claude flag and a project override are refused before any tab opens"
  for _ in 1 2 3; do
    listed=$(cd "$dir" && opencode debug agents --standalone) || fail "opencode debug agents exited $?"
    jq -e --arg id "$oc_agent" 'any(.[]; .id == $id)' <<<"$listed" >/dev/null && break
  done
  for file in "$oc_files"/*.md "$dir/opencode/agents/$oc_agent.md" "$dir/opencode/agents/e2e-no-model.md"; do
    want=$(sed -n 's/^model: //p' "$file")
    got=$(jq -r --arg id "$(basename "$file" .md)" '.[] | select(.id == $id) | .model | "\(.providerID)/\(.id)\(if .variant then "#" + .variant else "" end)"' <<<"$listed")
    [[ "$got" == "$want" ]] || fail "opencode lists the agent of $file on model '$got', wanted '$want'"
  done
  refused "of an unknown opencode agent" "has no global agent no-such-agent" --cwd "$work" --kind opencode --agent no-such-agent
  refused "of an opencode agent whose model opencode cannot reach" "does not list e2e/no-such-model" --cwd "$work" --kind opencode --agent e2e-no-model
  refused "without --agent" "--kind opencode needs --agent" --cwd "$work" --kind opencode
  refused "with --model" "--model: Claude only" --cwd "$work" --kind opencode --agent "$oc_agent" --model sonnet
  refused "of --agent with Claude" "--agent names an opencode agent" --cwd "$work" --agent "$oc_agent"
  mkdir -p "$dir/override/.opencode/agents"
  printf -- '---\npermissions:\n  - action: shell\n    resource: "*"\n    effect: allow\n---\n' >"$dir/override/.opencode/agents/$oc_agent.md"
  refused "in a project that overrides $oc_agent" "changes the permissions of agent $oc_agent" --cwd "$dir/override" --kind opencode --agent "$oc_agent"
  "$tools" agent start "$oc" --kind opencode --agent "$oc_agent" --cwd "$work" || fail "agent start --kind opencode exited $?"
  [[ "$(h agent get "$oc" | jq -r '.result.agent.agent')" == opencode ]] || fail "herdr does not list $oc as an opencode agent"
  "$tools" agent stop "$oc" || fail "agent stop of the opencode agent exited $?"
  agent_listed "$oc" && fail "the opencode agent is still listed after agent stop"
  tab_labelled "$oc" && fail "the opencode agent's tab is still open after agent stop"
else
  echo "step 13: skipped, opencode or ~/.config/opencode is missing on this host"
fi

if [[ -n "$codex_ready" ]]; then
  step 14 "a Codex agent starts in a git folder it has not trusted, with the CODEX_HOME, model, effort and sandbox of the caller and the brief, answers the brief and stops; a Claude-only flag, --agent, an unknown model, an unsupported effort and --effort without --model are refused before any tab opens"
  export CODEX_HOME="$dir/codex"
  git init -q "$dir/codex-work"
  refused "of --account with Codex" "--account: it picks a Claude account" --cwd "$work" --kind codex --account "$account"
  refused "of --permission-mode with Codex" "--permission-mode: it is a Claude mode" --cwd "$work" --kind codex --permission-mode plan
  refused "of --agent with Codex" "--agent names an opencode agent" --cwd "$work" --kind codex --agent "$oc_agent"
  refused "of an unknown Codex model" "lists no codex model no-such-model" --cwd "$work" --kind codex --model no-such-model
  refused "of a Codex effort the model does not list" "--effort no-such-effort is not one of" --cwd "$work" --kind codex --model "$codex_model" --effort no-such-effort
  refused "of a Codex effort without a model" "--effort needs --model with --kind codex" --cwd "$work" --kind codex --effort "$codex_effort"
  printf 'Reply with the single word ready and do nothing else.\n' >"$dir/codex-brief.md"
  "$tools" agent start "$cx" --kind codex --cwd "$dir/codex-work" --model "$codex_model" --effort "$codex_effort" --brief "$dir/codex-brief.md" || fail "agent start --kind codex exited $?"
  [[ "$(h agent get "$cx" | jq -r '.result.agent.agent')" == codex ]] || fail "herdr does not list $cx as a codex agent"
  [[ "$(tab_count "$cx")" == 1 ]] || fail "wanted one tab named $cx"
  cx_pane=$(h agent get "$cx" | jq -r '.result.agent.pane_id')
  cx_pids=$(h pane process-info --pane "$cx_pane" | jq -r '.result.process_info.foreground_processes[] | select(.name == "codex" or .name == ".codex-wrapped") | .pid')
  [[ -n "$cx_pids" ]] || fail "no codex process runs in pane $cx_pane"
  for pid in $cx_pids; do
    cx_argv=$(tr '\0' ' ' <"/proc/$pid/cmdline")
    grep -qF -- "codex -m $codex_model -c model_reasoning_effort=$codex_effort -s workspace-write -c sandbox_workspace_write.network_access=true -a never" <<<"$cx_argv" ||
      fail "codex started with other arguments: $cx_argv"
    tr '\0' '\n' <"/proc/$pid/environ" | grep -qxF "CODEX_HOME=$CODEX_HOME" || fail "codex runs without the caller's CODEX_HOME=$CODEX_HOME"
  done
  grep -qF -- "[projects.\"$dir/codex-work\"]" "$CODEX_HOME/config.toml" || fail "answering Codex's trust question saved no trust for $dir/codex-work in $CODEX_HOME/config.toml"
  wait_for 90 bash -c "\"$real_herdr\" --session \"$run\" agent read \"$cx\" --source recent-unwrapped | grep -q '^• ready'" ||
    fail "the codex agent did not answer its brief; its pane: $(h agent read "$cx" --source visible 2>&1 | grep -v '^\s*$' | tail -n 15)"
  h agent wait "$cx" --until idle --until "done" --timeout 60000 >/dev/null || fail "the codex agent did not settle after its brief"
  "$tools" agent stop "$cx" || fail "agent stop of the codex agent exited $?"
  agent_listed "$cx" && fail "the codex agent is still listed after agent stop"
  tab_labelled "$cx" && fail "the codex agent's tab is still open after agent stop"
else
  echo "step 14: skipped, codex, its auth.json or its models_cache.json is missing on this host"
fi

step 15 "agent start without --account spreads new agents and starts an account that burns its week fast last"
"$tools" usage --json --max-age 600 >"$dir/real-usage.json"
fast_acct=$(idle_profile)
slow_acct=$(idle_profile "$fast_acct")
[[ -n "$fast_acct" && -n "$slow_acct" ]] || fail "step 15 needs two signed-in profile accounts without a claude process"
mkdir -p "$dir/pick-cache" "$dir/pick-data" "$dir/pick-state"
jq --arg f "$fast_acct" --arg s "$slow_acct" '.accounts |= with_entries(select(.key == $f or .key == $s))' \
  "${CLAUDE_TOOLS_DATA:-$HOME/.config/claude-tools}/accounts.json" >"$dir/pick-data/accounts.json"
jq --arg f "$fast_acct" --arg s "$slow_acct" --argjson now "$(date +%s)" '
  def w($u; $left): {used: $u, resets_at: ($now + $left)};
  .updated = ($now + 600) | .hosts = []
  | .accounts |= map(select(.name == $f or .name == $s) | .checked = ($now + 600) | .scoped = [] | .plan = "team 5x"
      | .five_hour = w(10; 3 * 3600) | .seven_day = w(if .name == $f then 70 else 10 end; 5 * 86400))' \
  "$dir/real-usage.json" >"$dir/pick-cache/usage.json"
started_on() {
  local pane pid
  pane=$(h agent get "$1" | jq -r '.result.agent.pane_id')
  pid=$(h pane process-info --pane "$pane" |
    jq -r 'first(.result.process_info.foreground_processes[] | select(.name == "claude" or .name == ".claude-wrapped") | .pid) // empty')
  [[ -n "$pid" ]] || fail "no claude process runs in the pane of $1"
  tr '\0' '\n' <"/proc/$pid/environ" | sed -n 's/^CLAUDE_CONFIG_DIR=//p'
}
want=("$slow_acct" "$slow_acct" "$fast_acct")
for i in 1 2 3; do
  (cd "$dir" && CLAUDE_TOOLS_CACHE="$dir/pick-cache" CLAUDE_TOOLS_DATA="$dir/pick-data" CLAUDE_TOOLS_STATE="$dir/pick-state" \
    "$tools" agent start "$run-p$i" --cwd work --model haiku 2>"$dir/pick-$i.err") || fail "agent start $run-p$i exited $?: $(cat "$dir/pick-$i.err")"
  grep -qxF "claude-tools agent: $run-p$i starts on ${want[$((i - 1))]}" "$dir/pick-$i.err" ||
    fail "agent start $run-p$i did not say it starts on ${want[$((i - 1))]}: $(cat "$dir/pick-$i.err")"
  [[ "$(started_on "$run-p$i")" == "$("$tools" accounts dir "${want[$((i - 1))]}")" ]] ||
    fail "$run-p$i runs with CLAUDE_CONFIG_DIR=$(started_on "$run-p$i"), not ${want[$((i - 1))]}'s folder"
done
for i in 1 2 3; do "$tools" agent stop "$run-p$i" >/dev/null || fail "agent stop $run-p$i exited $?"; done

echo PASS
