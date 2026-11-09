# Sourced by agent-e2e.sh and limit-switch-e2e.sh. Needs h and fail from the caller.
foreign_available() {
  sudo -n -u sl-factory true 2>/dev/null && [[ -n "$(foreign_account)" ]]
}
foreign_account() {
  sudo -n -u sl-factory ls /home/sl-factory/.claude-accounts 2>/dev/null | head -n 1
}
foreign_pids() {
  pgrep -u sl-factory -x 'claude|\.claude-wrapped' || true
}
start_foreign_agent() {
  local name=$1 dir=$2 account shim pane
  account=$(foreign_account)
  shim="$dir/foreign-shim"
  mkdir -p "$shim"
  cat >"$shim/claude" <<SHIM
#!/usr/bin/env bash
exec sudo -n -u sl-factory -i sh -c 'config=\$HOME/.claude-accounts/$account/.claude.json; jq --arg folder "\$HOME" ".projects[\\\$folder].hasTrustDialogAccepted = true" "\$config" >"\$config.new" && mv "\$config.new" "\$config"; export CLAUDE_CONFIG_DIR=\$HOME/.claude-accounts/$account; exec claude "\$@"' claude "\$@"
SHIM
  chmod +x "$shim/claude"
  pane=$(h workspace create --cwd "$dir" --label "$name" --no-focus --env "PATH=$shim:$PATH" | jq -r '.result.root_pane.pane_id')
  h agent start "$name" --kind claude --pane "$pane" --timeout 120000 -- --model haiku --dangerously-skip-permissions >/dev/null ||
    fail "herdr could not start the agent that runs as sl-factory"
}
