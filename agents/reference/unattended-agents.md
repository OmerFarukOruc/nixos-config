# Unattended agents on devbox

Contents: an agent waits after its turn ends; a notice waits until its agent is idle; a restart keeps some loops; `/exit` waits on a dialog; a usage limit; a subagent stops on a usage limit; a herdr restart or reboot; an agent exits; a Status Lantern merge deploys staging; branches outlive their item; a rule given mid-run; `rm` on a variable path; `rm` inside a `-c` string; `pr-land` removes a worktree; the daily sweep removes a merged worktree; a review's fuzz runs a command.

This page covers Claude agents left running in herdr's default session while Omer is away. Each entry names a failure point, what handles it now, how to check it, and who sees a failure. A change to any of these paths names its own failure and who sees it, as nixos-config `agents/shared/reviews.md` (Reviews and audits) requires.

Terms used below:

- **Orchestrator**: an agent that prompts other agents and keeps their state in a board file, such as `~/handoffs/orchestrator/BOARD.md`.
- **Named agent**: a Claude agent that has a herdr name (`herdr agent list` shows it). `claude-tools limit-switch` acts only on named agents.
- **Resume message**: the first prompt `claude-tools limit-switch` sends to an agent after it starts the agent again (switch, restore, and `resume`). It is the text of `~/.config/claude-tools/resume/NAME` when that file exists, else "... Continue where you stopped."

## An agent waits forever after its turn ends

Claude Code acts only when a prompt arrives, so an agent that finished its turn stays idle until something sends it one.

- **Handled by:** a `/loop` in the agent's session, or an orchestrator that prompts it. The orchestrator wakes when one of its agents ends a turn or blocks, through a Monitor that runs `claude-tools agent watch` on herdr's agent events. It watches the agent names its regex argument matches, so an agent outside that regex gets no wake-up. An agent that needs the orchestrator while it keeps working sends `herdr agent prompt <orchestrator> "NEED <name>: <text>"`, which Claude takes into the orchestrator's running turn (`agents/reference/headless-clis/herdr.md`, section Orchestrating agents). The Monitor expires, so the orchestrator re-arms it, and a fixed-interval `/loop` stays as a fallback that re-arms the Monitor when it is missing.
- **Check:** after starting a `/loop`, run `CronList` in that session and record the job id in the board file ("Wake-up" in the orchestrator's `BOARD.md`). A loop that someone planned but nobody started looks the same as a working one until its first missed round, so a loop counts as started only when `CronList` shows its job.
- **Who sees a failure:** nobody, until a person or another agent reads the session. Rounds that stop leave no log entry.

## A notice waits until its agent is idle

An orchestrator that prompts only idle agents holds back a notice an agent is waiting on, such as a merge it depends on, until that agent's turn ends.

- **Handled by:** the orchestrator, which sends such a notice at once with `herdr agent prompt`. Claude Code does not interrupt a working agent; 2.1.316 takes the queued text into the turn it is running.
- **Check:** the agent's pane shows `Press up to edit queued messages` after the prompt.
- **Who sees a failure:** the orchestrator, when the agent's next report does not act on the notice.

## A restart keeps some loops and drops others

`claude --resume` restores a fixed-interval `/loop` (`/loop 10m ...`) that has not reached its 7-day expiry. It does not restore a self-paced `/loop` (one without an interval) or a Monitor (https://code.claude.com/docs/en/scheduled-tasks, Limitations). On Claude Code 2.1.300 a probe saw a `/loop 10m` job listed by `CronList` again after `/exit` and a resume in a new process.

- **Handled by:** the resume message. For an agent that runs a loop or a Monitor, write a resume message that checks before it starts anything, because a message that starts the fixed-interval `/loop` again leaves two copies running. Example: "Run CronList. If no job runs the orchestrator round, start `/loop 10m <round prompt>`. Start the agent Monitor again." The orchestrator's message is in `~/.config/claude-tools/resume/orchestrator` and needs the same check-first form.
- **Check:** after changing a loop, update the resume message to match, and after a restart run `CronList` once to see exactly one job per loop.
- **Who sees a failure:** nobody. An agent without a resume message gets the default text and runs without its self-paced loop or Monitor.

## `/exit` waits on a dialog while a loop is scheduled

When the session has a scheduled task, `/exit` opens "Background work is running" with the choices "Exit and stop tasks", "Move to background and exit", and "Stay", and Claude keeps running until someone answers (seen on Claude Code 2.1.300). In that probe, "Exit and stop tasks" still let `claude --resume` restore the `/loop 10m` job.

- **Handled by:** `claude-tools limit-switch`. After it types `/exit`, it watches the pane for 10 s and presses Enter on "Exit and stop tasks" when the dialog shows; `claude --resume` then brings the `/loop` back (the switch's e2e checks both). When the process is still there 30 s after that watch, it sends `ctrl+c` twice, which also closes the dialog (same 2.1.300 probe), and fails with `claude pid ... did not exit` after another 15 s.
- **Check:** `grep -E 'background-work dialog|did not exit' ~/.local/state/claude-tools/limit-switch/events.log`.
- **Who sees a failure:** `events.log` (next section). The agent stays on its old account.

## An account hits its usage limit

- **Handled by:** `claude-tools-limit-switch.timer`, which runs `claude-tools limit-switch scan` (nixos-config `pkgs/claude-tools`) every minute. The scan holds the account back until the reset its limit message names, in `~/.local/state/claude-tools/limits.json`, which `claude-tools rotate` shares. It then reads the usage of every account not held back and moves each named agent whose last output is a limit message to the first account of `claude-tools usage --order` (team accounts first, then the weekly-limited reserve, as nixos-config `pkgs/claude-tools/README.md` describes), then sends it its resume message. When the agent's own limit has reset by then, the agent stays on its account and gets only the resume message.
- **Check:** `~/.local/state/claude-tools/limit-switch/events.log`, and `events.log.1` for older lines once the log reached 1 MiB, `journalctl --user -u claude-tools-limit-switch.service -n 20`, and `jq . ~/.local/state/claude-tools/limits.json` for the accounts held back.
- **Who sees a failure:** the log only. When no account has room, the agent stays at the limit, and the scan logs it again every 5 minutes (`COOLDOWN` in the script).

## A subagent stops on a usage limit

An Agent-tool subagent that runs when its parent's account hits the limit ends with a `failed` notice that names the limit and the reset time, and its work so far stays saved (seen on Claude Code 2.1.323). `claude-tools limit-switch scan` reads only a named agent's own last output, never a subagent's, so it does not resume the subagent.

- **Handled by:** the orchestrator, or the parent when it has none. Once the parent's resume message has arrived or the reset time the notice names has passed, it sends `SendMessage` to the `task-id` in the notice. When the subagent had started a Codex pass (`codex-ask`, which runs under `setsid` and normally survives), the message gives the pass's `<tmp>/codex` folder and tells the subagent to read `<tmp>/codex/status` first: wait when it has no `exit` line, use `answer.md` after `exit 0`, and start a second pass only when the status shows the first one died. Start a new subagent only when `SendMessage` returns an error such as `No task found with ID`.
- **Check:** the `SendMessage` result reads `Resuming agent <id>`, and no second `failed` notice arrives.
- **Who sees a failure:** the orchestrator only; `events.log` has no line for a subagent. A second `failed` notice means send the message again after the new reset time.

## The herdr server restarts, crashes, or the box reboots

herdr's own restore starts a Claude pane as plain `claude --resume <id>`. That command loses the pane's `CLAUDE_CONFIG_DIR` (the account) and `--dangerously-skip-permissions`, so the agent runs on the default account and stops at every permission prompt.

- **Handled by:**
  - `[session] resume_agents_on_restore = false` in `~/.config/herdr/config.toml` turns herdr's own restore off, so the panes come back as shells. nixos-config `home-manager/modules/herdr.nix` writes it at each switch on every host that runs `claude-tools limit-switch`.
  - `claude-tools limit-switch scan` records each named agent (pane, session, account, arguments) in `~/.local/state/claude-tools/limit-switch/agents.json`. When the scan finds a new server process, it starts each missing agent like `clauded --resume <session>` on its recorded account and sends it its resume message.
  - When no server runs, the scan starts `herdr-default.service`. Lingering is on for `omer`, and the timer is enabled, so this also happens after a reboot.
- **Check:** `grep -A1 '^\[session\]' ~/.config/herdr/config.toml` shows the setting, and `events.log` has a `restored in pane` line for each agent.
- **Who sees a failure:** the log only. An agent whose restore failed stays in the record, and a scan tries again after 5 minutes (`COOLDOWN`); `claude-tools limit-switch restore` or `resume NAME` tries again at once.

## An agent exits by accident

- **Handled by:** an agent that exits while the same server runs moves to `ended` in `agents.json` with its last session. `claude-tools limit-switch resume NAME` starts it again like `clauded --resume <session>` on its recorded account and sends it its resume message. An ended entry leaves the record after 30 days (`ENDED_KEEP` in the script), and `resume` then fails with `no record of NAME`. A hand-written start loses the account or the flag.
- **Check:** `jq '.ended | keys' ~/.local/state/claude-tools/limit-switch/agents.json` lists the agents `resume` can start.
- **Who sees a failure:** the agent is gone from `herdr agent list`, which the orchestrator's round sees.

## A Status Lantern merge deploys staging

A merge to `main` in StatusLantern/statuslantern deploys staging-1 without a person: each push to `main` runs `.github/workflows/main.yml`, and its `deploy-staging` job runs after the `gate-main` job passes. Production needs a release (the repository's `release` skill).

- **Check:** `gh run list --workflow main.yml --commit <merge-sha>` in that repository gives the run's id, and `gh run view <run-id> --json jobs` shows the state of `gate-main`, `deploy-staging` and `release-tag`.
- **Who sees a failure:** the `notify-failure` job of the same workflow posts a failed or cancelled gate, staging deploy or release tag to the alert relay, the Worker that forwards alerts to Slack (`docs/observability.md` there). When `notify-failure` fails itself, for example because the relay does not answer 202, the failure shows only in GitHub Actions.

## Branches outlive the item that made them

Agents forget a branch once their item is done, and an agent that deletes one by mistake puts work at risk.

- **Handled by:** the orchestrator, as a standing duty of every round:
  - Every non-default branch in each repository the run works in has one line in the "Branches" section of the board file: repo, branch, owner agent or "unowned", PR, and fate ("merge via PR #n", "delete: merged in #n", "delete: superseded by <branch>", or "waiting on <item>").
  - Each round compares that section with `gh api repos/<owner>/<repo>/branches --paginate --jq '.[].name'` and with each agent's worktrees, and gives a new branch an owner and a fate the same round. When an owner reports an item done, the same reply asks it to land or delete every branch and worktree the item used.
  - Agents merge through `pr-land <n>`, which adds the `automerge` label where the merge controller exists; only Omer adds that label by hand, and a hook denies an agent's manual add. The merging agent first asks the orchestrator for the merge lock, which allows one merge into a repository's default branch at a time, and releases it when the PR is merged, `pr-land` stops without merging it, or Omer removes the `automerge` label.
  - A branch without a merged PR is deleted only after its owner records the proof on the board, and `git push --delete` comes after that. The proof is that `git cherry -v <successor or default> <branch>` prints no `+` line, or that a squash-merged PR carries the same change. Without that proof the branch stays and goes to Omer as a question.
  - Agents never delete a branch no agent owns, such as another person's or a Cursor or Codex run's; the orchestrator lists it for Omer once, with its age. Renovate branches belong to the Keeper bot, the bot that reviews Renovate pull requests and merges the ones it passes, and stay as they are.
- **Check:** the board's "Branches" section against the `gh api` list above.
- **Who sees a failure:** the next round's comparison shows a branch with no line, or a line whose branch is gone without a recorded proof.

## A rule given mid-run misses running subagents

A subagent sees only its own prompt and the messages sent to it, so a rule the orchestrator gives later, such as the load rule (heavy local runs through `heavy`, one at a time per agent) or a quiet window, does not reach subagents that already run.

- **Handled by:** the agent that receives the rule. It starts each subagent with a name, so `SendMessage` can reach it, sends the rule to each subagent it has running, and puts it in the prompt of each subagent it starts later.
- **Check:** each subagent repeats the rule in its next report, and the agent compares those reports with the subagents `ListAgents` shows.
- **Who sees a failure:** nobody directly. A subagent that starts a heavy run inside a quiet window pushes the load on devbox up again, and only its load average shows it.

## `rm` on a variable path is denied

Claude Code asks before an `rm` whose path starts with a variable that could be empty, such as `rm -f $d/*.txt`, even in bypass permissions mode. In an unattended session nobody answers, so the call is denied and the command does not run (the tool result says the prompt timed out or the session could not prompt, and that the command was NOT run).

- **Handled by:** the agent, which writes such a path as `"${d:?}"/name` or as a literal path, as the rule under "Claude Code" in nixos-config `agents/claude/CLAUDE.md` says. Claude Code also held `rm -rf sub/*` after a cd in the same call, and `rm -rf *` with or without a cd, quoted `'*'` included (2.1.300 and 2.1.301). A cd to the working directory does not count, because Claude Code drops it first. A variable set in the same call counts as set only when Claude Code can read its value: on 2.1.300 an absolute, quoted, `$HOME`, or exported value ran, while `d=~/x`, `d=$(mktemp -d)`, a backtick value, `d=$PWD/sub`, and `d=${HOME}/x`, each followed by an rm of `$d/*`, were held. A `~` in any value of the call and a name set twice to different values were held too.
- **Check:** the tool result starts with `Permission for this command was denied` and names a `Dangerous rm operation`.
- **Who sees a failure:** the agent, in that tool result.

## `rm` inside a `-c` string waits for a person

Claude Code holds a Bash call whose `bash -c`, `sh -c`, or `zsh -c` string contains `rm`, with the prompt "This shell -c script runs rm and could not be checked", in bypass permissions mode too. An agent hit it, and the orchestrator pressed Esc on it twice. The orchestrator reports that the prompt fires on any `rm` inside a `-c` string, a guarded path included, and saw no auto-deny countdown on it. Claude Code 2.1.300's source shows this prompt only when it cannot check the script, for example when the script defines a function or quotes `$@`. Nobody watched a held prompt to its end, so count on an unattended agent waiting until someone answers. This differs from the prompt in the previous section, which a timeout denies. The board's load rules still say the stop lasts about 2 minutes; the Esc observation is newer.

- **Handled by:** the `rm` rule under "Claude Code" in nixos-config `agents/claude/CLAUDE.md`, which says never to put `rm` inside a `bash -c`, `sh -c`, `zsh -c`, or `eval` string, a literal path included. On 2.1.300 Claude Code also held a call that names `rm` anywhere, in quoted text or a here-doc too, beside a `-c` string with a function, a positional parameter, and a word that starts with `$` where a command goes, such as `$1` or `p+=("$*")`. Clean up on its own line with a guarded path, such as `rm -f "${q:?}"`. When the cleanup must run inside a script, write the script to a file and run `bash <file>`. The orchestrator reports that Claude Code does not check `rm` inside a script file, and a reviewer whose `-c` call was held reran it from a script file without a prompt; no other case is recorded. An agent passes the rule to each subagent it runs, as the section on rules given mid-run says.
- **Check:** the agent's pane shows the prompt. For an agent the orchestrator's watcher follows, the watcher also prints a `BLOCKED` line for it. A prompt herdr does not recognise as a question shows as a `finished a turn` line after which the agent makes no progress.
- **Who sees a failure:** the orchestrator, through that watcher event, which it then clears by pressing Esc on the prompt. A held prompt in a subagent or an unwatched agent shows only in its own pane.

## `pr-land` removes the PR branch's worktree, whoever made it

After the merge, `pr-land <n>` removes the linked worktree that has the PR's head branch checked out when the branch tip equals or is contained in the PR head and `git status --porcelain` in it is empty, even when another agent, a Codex run, or Omer made that worktree. An untracked file keeps the worktree, but ignored files go with it. It removes the worktree with `wt remove --reap`, so the pre-remove hook stops a running `devenv up` there, and `--reap` stops the other processes still running in the folder when `lsof` lists them within 5 seconds, which it often does not on nixos-desktop (worktrees skill, Finish). The daily `worktree-sweep.timer` removes older merged worktrees with `wt step prune`, which keeps a dirty one or one younger than a day.

- **Handled by:** nixos-config `agents/shared/git.md` (Landing a PR) tells the landing agent to run `git worktree list` in the main checkout first, and `pr-land` itself does not ask. Before `pr-land <n>` it finds the worktree that has the PR's head branch. When such a worktree is not the agent's own, it asks the orchestrator before running the command.
- **Check:** `pr-land` prints `removed worktree <path>` for each worktree it removed, so the landing agent sees the removal only after it happened.
- **Who sees a failure:** the landing agent in that line, and the worktree's owner when its next command finds the directory gone.

## The daily sweep removes a merged worktree, whoever made it

`worktree-sweep.timer` (nixos-config `home-manager/modules/worktree-sweep.nix`) runs `wt step prune` once a day in each repository under `~/Desktop/workspace`. It removes each worktree and local branch whose changes are in the default branch, that has no uncommitted changes, and that is older than a day, including a detached worktree whose commit is in the default branch, such as an old `deploy-<sha7>`. Its pre-remove hook stops a running `devenv up` in the worktree first. A clean worktree whose branch still points at the default branch's commit counts as merged, so an agent that keeps one longer than a day loses it.

- **Handled by:** the worktrees skill, which removes each worktree when its task ends, so a worktree the sweep removes is a leftover. A dirty or unmerged worktree stays for its owner.
- **Check:** `/tmp/agents/worktree-sweep/report.md` lists, per repository, what the last run removed and kept; `journalctl --user -u worktree-sweep` has the same lines.
- **Who sees a failure:** a repository whose prune or listing fails gets a `sweep failed` line in the report, and the sweep goes on to the next repository. The run then fails the unit, so `systemctl --user --failed` shows `worktree-sweep.service`, and writes `~/.local/state/worktree-sweep/failed`, which every new zsh prints as a `worktree-sweep:` line until a run succeeds. A failed fetch only adds a line to the report, and that run measures merges against the local refs. The agent whose worktree went sees it when its next command finds the folder gone.

## A review's fuzz runs a generated command for real

A reviewer that checks a command parser against bash by running generated commands in a real shell runs whatever the generator builds. A fuzz input that wraps `pkill -f x` in `nohup` skips the reviewer's shell-function stubs, so the real `pkill` sends SIGTERM to every process of `oruc` with an `x` in its command line, which takes down rootless Docker, the user services, and a browser.

- **Handled by:** the `bash-guard.py` hook, which denies running a script, here-doc or corpus that holds both a process-execution construct and a kill command (`pkill`, `killall`, or `kill` with a signal or a target) unless the command starts with `sandbox-run` or each kill stops only the script's own background job saved once with `pid=$!`, and the agent that starts the reviewer. A reviewer prompt that omits the rule repeats the failure, so every reviewer and fuzz prompt says to never run a fuzzed or generated command in a real shell: call only the parser and the hooks with the command as data, use `bash -n` (it runs nothing), or run it with `sandbox-run [--rw DIR] -- <command>`, which gives it no view of the host's processes, network or user socket.
- **Check:** the reviewer's report has a line saying that it ran no generated command in a real shell, and how it got bash's reading.
- **Who sees a failure:** the agents whose services die, and only when they next use them. `systemctl --user --failed` misses a unit whose last process ended by SIGTERM, because `Restart=on-failure` treats that as a clean exit; openchamber stayed inactive with no failed state this way (`ExecMainStatus=15`). Compare `systemctl --user list-unit-files --state=enabled` with the units that run.
