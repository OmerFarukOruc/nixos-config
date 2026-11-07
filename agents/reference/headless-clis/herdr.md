# herdr on devbox

Written from `herdr 0.9.5` on devbox. It holds what `herdr --help`, `herdr <command> --help`, `herdr api schema --json`, and the `herdr` skill do not say: this box's install and sessions, and the gotchas agents hit. For command syntax, run the `--help` of the command. Vendor: <https://herdr.dev>.

## Install and sessions

- Home Manager installs herdr from the llm-agents flake input (nixos-config `home-manager/modules/applications.nix`), and nixos-config's updater moves that pin, so leave `herdr update` unused.
- The **default session** is where Omer's own agents run. `herdr-default.service` starts its server, and `claude-tools-limit-switch.timer` starts that unit when no default server runs. A server started from a terminal runs outside the unit, which then shows inactive. Socket `~/.config/herdr/herdr.sock`, log `~/.config/herdr/herdr-server.log`.
- Every session other than the default (`herdr --session <name> ...`) lives under `~/.config/herdr/sessions/<name>/`.
- Every session reads `~/.config/herdr/config.toml` unless `HERDR_CONFIG_PATH` points elsewhere. Each Home Manager switch writes the settings of nixos-config `home-manager/modules/herdr.nix` into that file, so change herdr settings there, not in the live file.
- nixos-config `home-manager/modules/herdr.nix` sets `[session] resume_agents_on_restore = false` on each host that runs `claude-tools limit-switch` (devbox), because herdr restores a Claude pane as plain `claude --resume <id>` (https://herdr.dev/docs/session-state/), which drops `--dangerously-skip-permissions` and the pane's `CLAUDE_CONFIG_DIR`. `claude-tools limit-switch` restores the agents instead; `../unattended-agents.md` covers restarts and `claude-tools limit-switch resume NAME`.

## Starting a Claude agent

`workspace create` and `tab create` print the new pane's id at `.result.root_pane.pane_id`, and the pane's shell gets `HERDR_ENV=1`, `HERDR_PANE_ID`, `HERDR_SOCKET_PATH`, and every `--env` pair.

Start Claude with `--dangerously-skip-permissions` after `--`, as Omer's `clauded` alias does. Set the account first, with `--env CLAUDE_CONFIG_DIR=...` on `workspace create` or `tab create`, or with `herdr pane run PANE "export CLAUDE_CONFIG_DIR=..."`. `start_claude` of `claude-tools limit-switch` handles every case below.

- **`agent_pane_busy`** right after the pane was created. Retry once a second; `start_claude` gives up after 60 s.
- **`agent_not_ready`**: Claude is blocked during startup. When `herdr agent read NAME --source visible` shows `Yes, I trust this folder`, it is the folder-trust question, which each account asks on its own; send `herdr agent send-keys NAME down`, then `enter`, then `herdr agent wait NAME --until idle`.
- **`agent_name_taken`** right after an agent with that name exited: herdr frees a name a moment after the process ends. Wait until `herdr agent get NAME` fails with `agent_not_found`.

A failed command prints JSON with the reason in `.error.code`.

## Starting a Codex agent

Create the tab with `tab create --label NAME --cwd DIR --no-focus`, then start Codex in its root pane with the sandbox open to the network:

```bash
herdr agent start NAME --kind codex --pane PANE -- -m <model> -c model_reasoning_effort=<effort> -s workspace-write -c sandbox_workspace_write.network_access=true -a never
```

- **`sandbox_workspace_write.network_access=true`** lets the agent reach the herdr socket, so its `NEED` and `DONE` prompts arrive, and lets `gh` reach GitHub. Without it, Codex 0.166.0's `workspace-write` sandbox refuses both: `codex sandbox -c sandbox_mode=workspace-write -- herdr agent list` fails with `Operation not permitted`, and adding the socket's folder to `writable_roots` does not help. The same command with `-c sandbox_workspace_write.network_access=true` lists the agents.
- **The first prompt names a skill as `$<skill-name>`** (operational-notes.md, Codex CLI).
- **One session covers one slice.** An interactive Codex session could not start subagents ("agent type is currently not available"), so a gpt-6.1-sol review of a 326-file pull request ended as a partial report. Split a large review into slices of whole files, about 14,000 head lines each, with one agent per slice.

## Reading an agent's answer

`herdr agent read NAME --source recent-unwrapped --lines N` returns the last N rows of an idle Claude agent's answer, although Claude draws on the terminal's alternate screen: herdr scrolls that screen to collect them and scrolls back (herdr 0.8.0 and later; a 200-line answer came back whole on 0.9.5). While the agent works or waits at a question, that read fails with `agent_not_idle`, so read `--source visible` then. The session transcript holds every answer as well: the session id is `herdr agent get NAME | jq -r .result.agent.agent_session.value`, and the transcript is `~/.claude/projects/*/<session>.jsonl`, shared by all accounts.

## Agent state

- Claude Code reports its states through `~/.claude/hooks/herdr-agent-state.sh`, which `herdr integration install claude` writes; `herdr integration status` shows the installed integrations.
- `herdr agent wait` fails at once with `agent_not_found` when the pane has no agent yet, so a watcher retries.
- `herdr pane report-agent` ignores a report whose `--seq` is missing or lower than the last one, so pass a growing value such as `date +%s%N` on every call.

## Panes and the socket API

- `herdr pane wait-output` also matches the echoed command line, so anchor a sentinel (`--regex '^EXIT [0-9]+$'` with `--source recent-unwrapped`) that the command line itself never matches.
- The socket takes one JSON request per line, `{"id": ..., "method": ..., "params": {...}}`, and answers one JSON line with `result` or `error`. `events.subscribe` takes `subscriptions: [{type: ...}]`; `pane.agent_status_changed` needs a `pane_id` in each subscription.

## Orchestrating agents

An orchestrator is an agent that starts other agents and reacts when they finish. herdr carries the messages and the agent states; three commands of nixos-config `pkgs/claude-tools` add what herdr lacks. They act on the default session, or on the session NAME with `CLAUDE_TOOLS_HERDR_SESSION=NAME`, as a test's scratch session does.

- `claude-tools agent start NAME --cwd DIR [--account ACCOUNT] [--model M] [--effort E] [--permission-mode MODE] [--brief FILE]` opens a tab named NAME in the caller's workspace without moving anyone's focus, starts Claude there as "Starting a Claude agent" describes, and sends one prompt that names FILE. ACCOUNT is an account name from `claude-tools accounts names` or a config folder, and defaults to the caller's own. NAME must match `[a-z][a-z0-9_-]{0,31}`, and a relative DIR is resolved against the caller's folder. When a step fails, it stops the agent it started, closes the tab, and exits 1 with the herdr error code, so the same command can run again. Use it instead of `pane split` for an agent that needs a name. It starts Claude only; start a Codex agent as "Starting a Codex agent" describes. For a plan-mode agent pass `--permission-mode plan`: it waits until the footer shows `plan mode on` before the brief goes out, and shift+tab key presses sent after the start are no substitute, because the screen read lags one key press.
- `claude-tools agent stop NAME [--force]` refuses with exit 1 while herdr shows the agent `working` or `blocked` at a question or approval, and prints the `herdr agent read` command for it, because an agent can still be writing to Omer after its DONE; wait with `herdr agent wait NAME --until idle --until done`, or answer its question, and pass `--force` only to cut it off on purpose. Otherwise it types `/exit` in a claude agent's pane, or presses Ctrl+C in a codex agent's pane until codex quits, waits until herdr frees the name, and closes the tab only when the tab is named NAME and holds that one pane. When herdr already dropped the name, it still closes such a tab and says so, which cleans up after an agent that `claude-tools agent watch` reported as unknown or gone. When the agent does not exit, when herdr still lists the name but no claude or codex process is found (the agent may be alive), or when no agent and no such tab exist, it exits 1 and leaves any tab open.
- `claude-tools agent watch NAME-REGEX [--host]` prints one line when an agent whose whole name the regex matches finishes a turn, waits at a question or approval (`BLOCKED`), turns unknown, appears, is replaced by an agent with another session, or leaves the agent list, so a Monitor on it wakes the orchestrator. It follows herdr's events, so it does not poll. herdr does not replay events from before a subscription, so the watcher prints each matching agent's state when it starts; re-arming the Monitor after a gap therefore still shows an agent that finished or blocked meanwhile. herdr counts any change from working or blocked to idle as a finished turn, so Esc on a question, or a prompt herdr does not recognise, also prints `finished a turn`; read the agent before you act on the line. When it loses herdr, it prints `ALERT watcher cannot follow herdr` and tries again every 5 s. When herdr answers `events_lost`, because the watcher fell behind the events herdr keeps, the watcher reads the agents and subscribes again without an `ALERT`. `--host` adds a line when load, swap use, or `/tmp` inodes cross their limits (2 x cores, 80 %, 70 %; guesses to tune). Two watchers print every line twice, so stop the old Monitor before you arm a new one. Pass a regex that matches the names you gave `claude-tools agent start`.
- Read an agent with `herdr agent get NAME` and `herdr agent read NAME --source recent-unwrapped --lines 120` ("Reading an agent's answer").
- An agent sends a question or a result to its orchestrator with `herdr agent prompt <orchestrator> "NEED <name>: <question>"` or `"DONE <name>: <result and report path>"`, without `--wait`, because it only delivers the text. The orchestrator therefore needs a herdr name: one that `agent start` did not start names itself with `herdr agent rename "$HERDR_PANE_ID" <orchestrator>`, and each brief names it. A prompt that reaches a working orchestrator does not interrupt it: Claude Code 2.1.316 takes the text into the turn it is running, so herdr reports both as one turn. herdr refuses the prompt with `agent_blocked` while the orchestrator waits at a question, and sends nothing then; the agent runs `herdr agent wait <orchestrator> --until idle --until done` and sends the text again. After any other error, the text may have arrived, so the agent reads `herdr agent read <orchestrator> --source visible` before it sends again.

- `herdr agent prompt` types into whichever conversation the Claude pane shows. While the pane shows one of the agent's subagents (its footer lists the agents, and the open one has a filled dot, `● implementer`), the prompt goes to that subagent's transcript, not to the main conversation (Claude Code 2.1.318, 2026-11-04: a prompt sent while `● implementer` was open landed in `subagents/agent-<id>.jsonl`). Before a prompt, read `herdr agent read NAME --source visible --lines 6` and send only while `● main` shows; afterwards, `grep` the main transcript for a phrase of the prompt.

Runbook for the orchestrator:

- After you start an agent, arm one Monitor on `claude-tools agent watch '<regex of your agents' names>'` before you end the turn, also while Omer is present, because a herdr agent is missing from Claude Code's agent panel. The watcher's `finished a turn` line is the wake signal; a `DONE` prompt from the agent is a convenience that a sandbox or a herdr error can stop. Read the agent and its report file on each line.
- A `DONE` prompt arrives while the agent's turn still runs, and the text it writes after the prompt can ask Omer something. Before `claude-tools agent stop`, run `herdr agent wait NAME --until idle --until done` and read its last message; anything it still asks of Omer is answered or moved to his list first.
- When Omer is online, ask a question that blocks an agent with AskUserQuestion at once, one question per call.
- Run one round of questions before a grill starts and one right after it ends.

Footer for every dispatch brief:

```
- Your orchestrator is the herdr agent `<orchestrator>`. When you wait for a reply, run `herdr agent prompt <orchestrator> "NEED <your name>: <question>"`; when you finish, run `herdr agent prompt <orchestrator> "DONE <your name>: <result and report path>"`. When herdr answers `agent_blocked`, run `herdr agent wait <orchestrator> --until idle --until done`, then send it again.
- Run a generated, corpus, or probe command that contains pkill, killall, or kill only through `sandbox-run`, never in the real shell.
- Write refuses a report file from a subagent. That is expected. Write the report with a Bash here-doc to the path you were given.
```
