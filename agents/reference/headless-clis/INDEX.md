# Headless CLI docs

Before composing a headless command for one of these CLIs, save its live docs page to a file and read the sections the command needs, then confirm each flag with the installed binary's `--help`, because the docs lag the binaries:

```sh
curl -fsSL <docs page> -o /tmp/agents/<task>-<session8>/<cli>.md
```

| CLI | Command on this host | Docs page |
| --- | --- | --- |
| Claude Code | `claude` | https://code.claude.com/docs/en/headless.md |
| Grok | `grok` | https://docs.x.ai/build/cli/headless-scripting.md |
| Codex `codex exec` | `codex` | https://learn.chatgpt.com/docs/non-interactive-mode.md |
| Codex subagents (`[agents]`, per-agent model) | `codex` | https://learn.chatgpt.com/docs/agent-configuration/subagents.md |
| Cursor | `cursor-agent`; `agent` starts Grok's launcher here | https://cursor.com/docs/cli/headless.md |
| Antigravity | `agy` | https://antigravity.google/docs/cli/headless.md |
| OpenCode | `opencode` | https://opencode.ai/docs/cli/commands.md |

Two files here are written from live sessions, not vendor pages:

- `operational-notes.md`: what the docs pages omit or get wrong, per CLI.
- `herdr.md`: herdr on devbox: install, sessions, starting and reading Claude agents, gotchas.
