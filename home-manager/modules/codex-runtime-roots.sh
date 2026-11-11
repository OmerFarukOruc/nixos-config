#!/usr/bin/env bash

root_dir="${XDG_STATE_HOME:-$HOME/.local/state}/codex-chatgpt-runtimes"
mkdir -p "$root_dir"
exec 9>"$root_dir/lock"
flock 9

if ! paths=$(
  codex mcp list --json 2>/dev/null | jq -r '
    .[] | select(.name == "node_repl" or .name == "cua_repl")
    | .transport | .. | strings
    | scan("/nix/store/[0-9a-z]{32}-chatgpt-unwrapped-[A-Za-z0-9+._?=-]+")
  ' 2>/dev/null | sort -u
); then
  echo "Could not read Codex MCP server settings" >&2
  exit 1
fi

while IFS= read -r path; do
  if [[ -n "$path" && -e "$path" ]]; then
    nix-store --realise "$path" --add-root "$root_dir/${path##*/}" >/dev/null
  fi
done <<<"$paths"

for root in "$root_dir"/*-chatgpt-unwrapped-*; do
  [[ -L "$root" ]] || continue
  target=$(readlink "$root")
  if ! grep -Fxq -- "$target" <<<"$paths"; then
    rm -- "$root"
  fi
done
