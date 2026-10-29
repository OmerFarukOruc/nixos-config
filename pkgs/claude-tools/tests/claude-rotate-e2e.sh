#!/usr/bin/env bash
set -euo pipefail
rotate="$(readlink -f "${1:-$(dirname "$0")/../bin/claude-rotate}")"
profiles="$(dirname "$rotate")/claude-accounts"
usage_bin="$(dirname "$rotate")/claude-usage"
A="${CR_E2E_A:-work1-team}" C="${CR_E2E_C:-work2}" R="${CR_E2E_R:-work1}"
dir=$(mktemp -d /tmp/cr-e2e.XXXXXX)
run="cr-e2e-$(basename "$dir" | cut -d. -f2 | tr '[:upper:]' '[:lower:]')"
t() { tmux -L "$run" "$@"; }
ok=0

cleanup() {
  t kill-server 2>/dev/null || true
  [[ -z "${wrapper:-}" ]] || rm -f "${XDG_RUNTIME_DIR:-/tmp/claude-rotate-$(id -u)}/claude-rotate/$wrapper-"*.json
  if ((ok)); then rm -rf "$dir"; else echo "kept $dir"; fi
}
trap cleanup EXIT
fail() {
  echo "FAIL: $*"
  t capture-pane -p -t "$run" 2>/dev/null | grep -v '^\s*$' | tail -12 >"$dir/pane.log" || true
  exit 1
}

for n in "$A" "$C" "$R"; do
  "$profiles" names | grep -qx "$n" || fail "no account $n here"
done

"$usage_bin" --json --max-age 600 >"$dir/real-usage.json"
jq --arg a "$A" --arg c "$C" --arg r "$R" --argjson now "$(date +%s)" '
  def w($u): {used: $u, resets_at: ($now + 3600)};
  .updated = $now | .hosts = []
  | .accounts |= map(.state = "ok" | .five_hour = w(95) | .seven_day = w(95)
      | if .name == $a then .five_hour = w(1) | .seven_day = w(1)
        elif .name == $c then .five_hour = w(0) | .seven_day = w(0)
        elif .name == $r then .five_hour = w(1) | .seven_day = {used: 1, resets_at: ($now + 6 * 86400)} else . end)' \
  "$dir/real-usage.json" >"$dir/usage.json"
mkdir -p "$dir/state"
jq -n --arg c "$C" --argjson u "$(($(date +%s) + 3600))" '{($c): {until: $u, reason: "e2e seed"}}' >"$dir/state/limits.json"

t new-session -d -s "$run" -x 200 -y 50 \
  "cd $dir && exec env -u CLAUDE_CONFIG_DIR -u CLAUDE_ROTATE_ID CLAUDE_USAGE_CACHE=$dir/usage.json \
CLAUDE_ROTATE_STATE=$dir/state $rotate --model haiku \
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
  local p env
  for p in $(pgrep -x 'claude|\.claude-wrapped'); do
    env=$(tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null) || continue
    grep -qx "CLAUDE_ROTATE_ID=$wrapper" <<<"$env" || continue
    [[ "$(awk '{print $4}' "/proc/$p/stat")" == "$wrapper" ]] || continue
    printf '%s\t%s\t%s\n' "$p" "$(sed -n 's/^CLAUDE_CONFIG_DIR=//p' <<<"$env")" "$(tr '\0' ' ' <"/proc/$p/cmdline")"
    return
  done
}
account_of() {
  local n
  for n in $("$profiles" names); do [[ "$("$profiles" dir "$n")" == "$1" ]] && {
    echo "$n"
    return
  }; done
  echo "unknown:$1"
}
type_line() {
  t send-keys -t "$run" -l "$1"
  sleep 1
  t send-keys -t "$run" Enter
}
# Each account trusts a folder on its own, so a new claude may first ask about the run folder.
settle() {
  local screen
  for _ in $(seq 60); do
    screen=$(t capture-pane -p -t "$run")
    if grep -q "Yes, I trust this folder" <<<"$screen"; then
      t send-keys -t "$run" Down Enter
      sleep 3
      continue
    fi
    grep -q '^❯' <<<"$screen" && [[ -n "$(child)" ]] && return
    sleep 1
  done
  fail "claude did not reach its input box in 60 s"
}
settle
first=$(child)
[[ -n "$first" ]] || fail "claude-rotate started no claude"
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
[[ ! -d "/proc/$wrapper" ]] || fail "claude-rotate still runs 20 s after /exit"
[[ "$(t display -p -t "$run" '#{pane_dead_status}')" == 0 ]] || fail "claude-rotate exited $(t display -p -t "$run" '#{pane_dead_status}')"
[[ -z "$(child)" ]] || fail "a claude of this run outlived /exit"
echo "exit: /exit ended claude-rotate with exit code 0"

t new-session -d -s "$run-q" -x 200 -y 50 \
  "cd $dir && exec env -u CLAUDE_CONFIG_DIR -u CLAUDE_ROTATE_ID CLAUDE_USAGE_CACHE=$dir/usage.json \
CLAUDE_ROTATE_STATE=$dir/state $rotate --model haiku"
t set-option -t "$run-q" remain-on-exit on
picker "$run-q" >/dev/null
t send-keys -t "$run-q" q
for _ in $(seq 10); do
  [[ "$(t display -p -t "$run-q" '#{pane_dead}')" == 1 ]] && break
  sleep 1
done
[[ "$(t display -p -t "$run-q" '#{pane_dead}')" == 1 ]] || fail "claude-rotate still runs 10 s after q in its picker"
[[ "$(t display -p -t "$run-q" '#{pane_dead_status}')" == 0 ]] ||
  fail "q made claude-rotate exit $(t display -p -t "$run-q" '#{pane_dead_status}')"
echo "quit: q in the picker started nothing"
ok=1
echo PASS
