# Claude account tools

`claude-tools` runs several Claude Code accounts on one machine at the same time, one config folder per account, shows their usage and logins, and keeps Claude agents in herdr running across usage limits. It runs on nixos-desktop and nixos-rog under `oruc`, and on devbox under `omer`. Home Manager installs it (`home-manager/modules/claude-tools.nix`). The account list `accounts.json` and the shared preferences `account-prefs.json` hold emails and organizations, so they stay in the private dotfiles checkout's `desktop/claude-code`; `CLAUDE_TOOLS_DATA` names another folder.

`claude-tools --help` lists the commands, and each command prints its own `--help`; `claude-tools accounts help` lists the account commands.

| Command | What it does |
|---|---|
| `accounts` | account folders, links, preferences and logins (`libexec/claude-accounts`, bash) |
| `usage` | the usage cards, the cache, `--order` |
| `rotate` | runs `claude` with the account picker and moves a session at a usage limit |
| `limit-switch` | moves herdr agents at a usage limit and starts them again after a herdr restart |
| `agent start\|stop\|peek` | named Claude agents in herdr tabs |
| `orch notify\|watch` | notices between agents and their orchestrator |

## Package layout

- `src/claude_tools`: the Python package, stdlib only. `cli.py` holds the argument parser. `commands/` holds one module per command with its workflow, and the modules beside it hold what several commands share: `settings.py` (paths and environment, read once per run), `accounts.py`, `usage.py` (reading and caching usage), `selection.py` (the account order), `terminal.py` and `picker.py` (cards and the account list), `herdr.py`, `agents.py` (Claude and codex processes in herdr panes), `transcripts.py`, `limits.py` and `inbox.py`.
- `libexec/`: `claude-accounts`, which `claude-tools accounts` runs with the rest of its arguments; `login-browser`, the `BROWSER` of a login; `config-lock.sh`, the `.claude.json` lock that `claude-accounts` sources. They stay bash because the lock reads a file's birth time with `stat`, which Python 3.14 cannot read.
- `share/claude-tools.sh`: the `claude` shell function and the completion of `claude-tools`, for zsh and bash. Home Manager's zsh sources it.
- `pkgs/claude-tools.nix` builds the package with `buildPythonApplication` and writes the store paths into `settings.py`, `claude-accounts` and `claude-tools.sh` in place of `@bin@` and `@libexec@`.
- The package holds no comments or docstrings: facts that are not usage live in this README, usage lives in `--help`, and lint settings live in `ruff.toml` and `.shellcheckrc`.

## Files and environment

| Path | Holds |
|---|---|
| `~/.cache/claude-tools/usage.json` | each account's usage and login state, and the copies of the other hosts' files |
| `~/.cache/claude-tools/probe` | the folder the one-turn usage probe runs in |
| `~/.cache/claude-tools/rotate` | `claude --help` of the installed binary |
| `~/.local/state/claude-tools/limits.json` | the accounts held back after a usage limit, shared by `rotate` and `limit-switch` |
| `~/.local/state/claude-tools/rotate` | `events.log` of `rotate` |
| `~/.local/state/claude-tools/limit-switch` | `agents.json`, `switched.json`, `restore-failed.json`, `events.log` and `events.log.1` of `limit-switch` |
| `~/.local/state/claude-tools/orch` | the inbox `inbox.log`, its `.offset` and `.watcher` files, and `notes/` |
| `~/.config/claude-tools/resume/NAME` | the resume message for agent NAME |
| `$XDG_RUNTIME_DIR/claude-tools/rotate/ID-PID.json` | the limit handshake between `rotate` and the StopFailure hook |

| Variable | Effect |
|---|---|
| `CLAUDE_TOOLS_DATA` | the folder with `accounts.json` and `account-prefs.json` |
| `CLAUDE_TOOLS_CACHE` | the cache folder |
| `CLAUDE_TOOLS_STATE` | the state folder |
| `CLAUDE_TOOLS_INBOX` | the orchestrator inbox |
| `CLAUDE_TOOLS_HERDR_SESSION` | a herdr session other than the default one |
| `CLAUDE_TOOLS_PICK=0` | `rotate` starts on the first account without the list |
| `CLAUDE_TOOLS_PLAIN=1` | the `claude` function runs plain `claude`; agents that `limit-switch` and `agent start` start get it |
| `CLAUDE_TOOLS_ROTATE_ID` | set by `rotate` on its Claude process; the hook writes the handshake under it |
| `CLAUDE_TOOLS_LOGIN_BRAVE_PROFILE`, `CLAUDE_TOOLS_LOGIN_URL_FILE` | set by `accounts login` for `login-browser` |

`CLAUDE_CONFIG_DIR` is Claude Code's own variable.

## Accounts

| Account | Folder | `CLAUDE_CONFIG_DIR` | Account config |
|---|---|---|---|
| The main account (named in `~/.claude/.claude-profile-name`; without that file, the accounts.json account its login matches, written there, else `main`) | `~/.claude` | unset | `~/.claude.json` |
| Every other account | `~/.claude-<folder>`, marked by a `.claude-profile` file | `~/.claude-<folder>` | `~/.claude-<folder>/.claude.json` |

An extra account's name is the content of its `.claude-profile` file, or `<folder>` when the file is empty; `add` and `rename` write the name into it. `rename` moves an idle account's folder to `~/.claude-<new name>`. While a session runs with the account, `rename` leaves the folder where it is, because the session keeps writing to the path in its `CLAUDE_CONFIG_DIR`. That folder still holds the old name's path, so `add` and `rename` put a new account with that name in `~/.claude-<name>-2` (or `-3`, and so on).

- Each machine logs in to each account on its own, with a browser login (setup-token logins cannot run Remote Control). Never copy a `.credentials.json` to another machine: Claude Code rotates the refresh token on use, so the first refresh on one machine logs the other out. For the same reason no tool of ours refreshes a token (Usage).
- An email that belongs to several organizations, such as a personal Max plan and a Team seat, needs one account per organization, because a login holds one organization. After `add`, the Org column of `list` shows which organization the login picked; `personal` is the email's own organization. The plan column adds the usage tier (5x, 20x), which only the credentials file holds, as `rateLimitTier`.
- Each extra folder symlinks the entries in the script's `shared` array to `~/.claude`, so settings, skills, hooks, rules, plugins, themes, sessions (`projects`), rewind checkpoints (`file-history`), and plans are one copy for every account. A session resumed under another account keeps its session ID and numbers its checkpoints from that account's `file-history`, so a separate copy per account reuses checkpoint names and rewind can restore another account's file content. Claude Code creates `projects`, `plans` and `file-history` in `~/.claude` only when the main account runs, and a profile cannot create them through its link, so `add` and `update` create them when they are missing; without them a profile's sessions are never saved and `--resume` finds nothing. `list` shows `broken` for a link that points at nothing.
- `history.jsonl` (the prompt history behind the up arrow) stays per account. Claude Code 2.1.292 never reads or writes it through a symlink, and its retention prune rewrites the file, which would break a hard link.
- `.credentials.json` and `.claude.json` stay per folder. Claude Code rotates the OAuth refresh token on use, so two accounts sharing one credentials file log each other out. `.claude.json` holds the account identity next to the MCP servers.
- `.claude.json` also holds preferences that some commands save per account, such as the `/focus` view (`briefTranscript`), so a new profile starts without them. Put a preference every account shares in `settings.json` when it has a key there and /config still shows its row, as `"viewMode": "focus"` does for focus view. `cc-setting KEY` shows whether a key has a `settings.json` key. Otherwise add the key and its value to `account-prefs.json`. That includes `workflowSizeGuideline`: it has a `settings.json` key, but /config hides "Dynamic workflow size" while a settings file sets it. `claude-tools accounts prefs` merges the file with `~/.claude.json` and every profile's `.claude.json` (`json-config.py sync_prefs` in the dotfiles checkout). A value changed in /config in any account goes into the file and every other account, and a value changed in the file goes into every account. When two sides changed one key to different values, it changes nothing for that key and prints the values on each run until they are equal. `desktop-sync.sh` runs it, and the hourly `desktop-sync-config.timer` on both hosts commits the file, so a change reaches the other host within about two hours.
- `claude-tools.sh` makes `claude` a shell function: `claude --account NAME` runs one session on NAME, and an interactive `claude` in a terminal without `CLAUDE_CONFIG_DIR`, `CLAUDE_TOOLS_ROTATE_ID` or `CLAUDE_TOOLS_PLAIN` runs `claude-tools rotate`.

## Logins

- `accounts.json` lists every account with the email and organization its login must show and the display name of the Brave profile that holds its claude.ai session. An account name means the same login on every device; the `~/.claude` account's name file says which one it is there (`own-team` on devbox, `work1` on nixos-rog).
- `accounts login NAME` creates the account's folder when the device has none, runs `claude auth login --claudeai --email EMAIL` with `BROWSER=libexec/claude-tools/login-browser`, and then checks `claude auth status` against accounts.json. A login that picked the wrong organization fails with both values printed and is logged out again.
- `login-browser` opens the authorize URL in the Brave profile whose display name is `CLAUDE_TOOLS_LOGIN_BRAVE_PROFILE`, so the claude.ai session of that profile signs in; unset or empty opens Brave's last profile. Each device resolves the name to its own profile folder through the browser's `Local State` file (Brave is brave-origin on nixos-desktop and nixos-rog). A name the device has no profile for gets a new profile in the folder `Claude <name as a slug>`: its `Preferences` file names it before Brave first opens it, and Brave takes that name into its profile list (checked on 19-10-2026 with brave-origin and a scratch `--user-data-dir`). An existing folder is never written. With `CLAUDE_TOOLS_LOGIN_URL_FILE` set, it writes the URL to that file and opens nothing.
- `login NAME --on HOST` runs the same login on HOST in a tmux session there, under `timeout --foreground`, because without `--foreground` claude stops on its first terminal read (state T) before it prints the URL. The remote `login-browser` writes the URL to a file; this device opens it and tunnels the browser's redirect to the remote claude's `localhost` port with `ssh -L`.
- `login-window` is the widget's Log in button. It runs `login` in a new Ghostty or Konsole window with `~/.local/bin` on `PATH`, because plasmashell, which starts it, has no `~/.local/bin` on `PATH`, where `claude` lives on two hosts.
- `login-all --list` prints the accounts that are missing, logged out, or end within 5 days; `login-all` logs in to each of them.

## Usage

- `claude-tools usage`, which `claude-tools accounts` without a command runs for the cards, writes each account's 5 h and 7 d use, reset times, login end and state to `~/.cache/claude-tools/usage.json` (`claude-tools-usage.timer`, every 10 min). `claude-tools` adds `~/.local/bin` to `PATH` before any command, for the same plasmashell reason as `login-window`, because the widget runs it and `rotate` and `limit-switch` probe accounts in the same process.
- It never refreshes a token. While an account's access token stays valid for more than 5 min, it reads the usage endpoint with that token. Otherwise, and when the endpoint answers 401, it runs a one-turn `claude -p` on haiku in `~/.cache/claude-tools/probe` and reads the `rate_limit_event`, so Claude Code refreshes the token itself and writes the new one to its own credentials file. Only the probe's `result` event and its stderr name a failure, because its `init` event lists commands such as `/login`. A failed reading keeps the last numbers and marks them stale.
- Logins on other devices show in the cards because `remote_hosts` in accounts.json names, per device, the devices whose cache it reads over ssh. A device whose everyday key has a passphrase reads with `~/.ssh/id_ed25519_claude_usage`, which the target accepts only for `cat .cache/claude-tools/usage.json`: nixos-config `machines/nixos-rog/claude-tools-usage-read.nix` declares it for nixos-rog.
- The cards show one card per account in accounts.json, and the widget (`pkgs/claude-accounts-widget`) one row per account in accounts.json; an account a host has that accounts.json does not list does not appear, and the widget's login badge and best account ignore it too. The widget's best account is the first of `usage --order` (the `order` list of `usage --json`), the one `rotate` would start on. Usage limits belong to the account, so each account appears once with the newest reading from any host, a fresh one before a stale one, followed by one login line per host (`no login` means that host never logged in to it). `usage --json` adds this list as `combined`, and `usage --watch` redraws the cards every 30 s. A pace mark follows each percent: ▲ when the account uses the window faster than an even spread to the reset, ▽ when it has room to spare, ≈ within 5 points of even. A reset clock adds 30 s, because the API's reset times sit a fraction of a second either side of the full minute.

## Rotation

- `claude-tools rotate` opens each interactive `claude` with an account list: every account here with its 5 h and 7 d bars and pace, best first, with the reason for each place, and the highlighted account's windows and login below. Enter starts the highlighted account, 1-9 start a row, `r` checks every account's usage now and opens the list again, and `q` starts nothing. Accounts logged out on this host are listed but cannot be picked. A list that fails to open starts the recommended account.
- `usage --order` prints the same order. Team accounts, which have no weekly limit, come first, and the weekly-limited accounts follow as the reserve. A reserve account moves to the top when our burn rate (the use per hour of every running 5 h window, at least one 5x window spread evenly) could not spend its weekly room before the weekly reset, because that room would otherwise go unused. Inside each group, an account whose 5 h room lasts to its 5 h reset at our burn rate goes before one that would hit the 5 h limit first, so a move does not land next to a 5 h limit. Team accounts that last go soonest reset first, so the room that comes back soonest is spent first; those that do not go by the most room in 5x units, and reserve accounts by weekly reset. Accounts held back after a limit, at 90% of 5 h or 95% of 7 d, or without a reading go last.
- `rotate` and `limit-switch` choose the next account the same way (`selection.py`). After a usage limit, `hold_limit` holds the account back until the reset that the limit message names. A message without a reset time, such as a model limit, holds it until the reset of a full window in a reading taken then, else for 1 h. A reset time more than one window ahead (5 h for a session limit, 7 d for a weekly one) belongs to an old message, so it holds nothing. The holds live in one file, `~/.local/state/claude-tools/limits.json`, written under a lock, with ended holds dropped on each write; a new hold replaces the account's earlier one, because the newest limit message is the latest word. `next_account` then reads the usage of every account that is not held back and was not read in the last minute, for at most 2 min, and returns the first of the order that nothing blocks.
- `rotate` passes every argument to `claude`. It reads `claude --help` once per installed binary, because it costs a node start, to learn which options take values and which words are subcommands; a subcommand, `-p`, `--version`, `--help` or a run without a terminal runs plain `claude`.
- It starts each session on the chosen account and moves the session to the next account when its turn fails on a usage limit: the StopFailure hook `desktop/claude-code/hooks/rotate-on-limit.sh` of the dotfiles checkout writes the hook input to `$XDG_RUNTIME_DIR/claude-tools/rotate/ID-PID.json`, which carries the limit message as `last_assistant_message`. `rotate` holds the account, stops the session and resumes it with `--resume` on the next account. When no account is free, it waits until the first time any account, its own included, leaves the blocked group, else 1 h, and then resumes the session on the best account, its own one too when that limit has reset. A prompt typed into the session after the limit cancels the move and the wait.

## Limit switch

`claude-tools limit-switch scan` keeps Claude agents in herdr running; `claude-tools-limit-switch.timer` runs it every minute on devbox.

- A scan first restores, then switches each named Claude agent whose screen ends in a limit message. A switch types `/exit` in the agent's pane, sets `CLAUDE_CONFIG_DIR` there, starts Claude like `clauded --resume <session>` with its other old arguments under the same agent name, and tells the agent to continue. Omer's `clauded` alias adds `--dangerously-skip-permissions`, so an agent never stops at a permission prompt after a switch. The accounts share `~/.claude/projects`, so `claude --resume <session>` continues the same conversation under another account. A scan holds the account and moves the agent to `next_account`. When that is the agent's own account, because its limit has reset, the scan only sends the resume message.
- `~/.config/claude-tools/resume/NAME` replaces the resume message for agent NAME. `--resume` brings back a fixed-interval `/loop` but not a self-paced one or a Monitor, so an agent that runs them needs a message that checks CronList first (the dotfiles checkout's `desktop/reference/unattended-agents.md`). With a scheduled task, `/exit` opens "Background work is running"; the switch presses Enter only on its selected first choice "Exit and stop tasks", so a screen that only quotes the dialog gets no Enter.
- herdr itself resumes Claude as plain `claude --resume`, without the flag and the account (the dotfiles checkout's `desktop/reference/headless-clis/herdr.md`), so its own restore is off. Each scan records the named Claude agents and the server process in `agents.json`. When the next scan finds a different server process, it starts each recorded agent that is missing like `clauded --resume <session>` with its account, in its old pane or a new workspace, and sends it the resume message. An agent that is missing while the same server runs was ended on purpose; the record keeps it under `ended` with its last session for 30 days, and only `resume NAME` starts it again, the same way. `resume` restores first, because after a server restart the other missing agents need the restore, and the record would otherwise mark them as ended. When no server runs, a scan starts it (`herdr-default.service` for the default session).
- A start waits until the pane's shell runs typed input: in a folder with an `.envrc` the shell first loads direnv, and text typed during that load shows on screen but never runs. A start that fails closes the workspace it made.
- A scan skips an agent for 5 min after a move it tried, and a restore waits 5 min after a failed start, because the screen keeps the old limit message until the agent answers, and a scan every minute would otherwise try again on each run.

## Agents and the orchestrator

- `agent start NAME --cwd DIR` opens a tab named NAME in the caller's workspace with `--no-focus`, so the view of whoever looks at herdr stays where it is. With `CLAUDE_TOOLS_HERDR_SESSION` the tab opens in that session's own workspace, because the caller's pane id belongs to its own session. The brief goes as one prompt that names the file, so a long brief never goes through argv. `--permission-mode` waits until the footer shows the mode before the brief goes out, because a mode switched by keypresses after start raced the brief once. A name whose agent just exited is waited for, since herdr frees it a moment later. When any step fails after the tab exists, the agent that started is stopped and the tab is closed, so the same command can run again.
- `agent peek` reads the last answer from the session transcript, because the screen can miss an answer on Claude's alternate screen (the dotfiles checkout's `desktop/reference/headless-clis/herdr.md`).
- `orch watch` reads a word that starts with `-` as an option and never as its regex, because a watcher that took it as a name pattern would print the unread notices and move the shared offset, so the orchestrator's own watcher would lose them. One watcher runs per inbox; a new one stops the older one only when the lock holder's command line runs the same program with `orch watch`, and refuses to start next to any other holder.

## Config lock

`claude-accounts` rewrites a `.claude.json` only while it holds the lock directory `<file>.lock` (`libexec/config-lock.sh`). Claude Code holds the same directory while it writes the file (a mkdir lock, read from the 2.1.301 binary: stale after 10 s without an mtime change), so a write of a live session cannot land between the read and the move.

- Our holds are well under 10 s, so the helper never refreshes its lock. A holder that keeps one longer can lose it to a stale break; the break is best effort between our own runs. Our runs take turns on `<lock>.break` and read the age again inside the turn, so a lock another run broke and took meanwhile is not removed. The empty `.break` file stays, because removing it while another run waits on its flock lets a third run make a new file and take a second flock, and then two runs break at once.
- The lock directory stays empty, as Claude Code expects, so Claude Code can break a lock a dead holder of ours left. A holder recognises its own directory by inode plus birth time, read right after `mkdir`; a filesystem that reports no birth time fails the lock. `lock` and `unlock` run in the same shell, because the identity lives in a variable of that shell. Two directories created within one kernel clock tick can share both values (about 4 ms on kernel 6.12, finer with multigrain timestamps from 6.13). The check and the `rmdir` of an unlock are two commands, so a lock taken between them is lost.
- `claude_config_lock_all` takes the locks of several files, in order, or none. It waits half a second for each; when one is held, it releases the others and tries again after a growing pause until 10 s have passed, so no lock it holds ages toward Claude Code's 10 s bound while it waits. A held lock fails the call with "config: not changed" and changes no file.

## Invariants

Keep these true in every change:

- The main account's files stay in `~/.claude`. The default claude-desktop-extra profile and the IDE extensions read only that folder, and Claude Code finds `~/.claude.json` only with `CLAUDE_CONFIG_DIR` unset. Never run the main account with `CLAUDE_CONFIG_DIR=~/.claude`: that writes a second config, `~/.claude/.claude.json`, and a login there leaves `~/.claude.json` naming the old account, so `list` shows the wrong email. `list` marks the main account's links `split` while that file exists. Renaming the main account writes its name file; deleting it is refused.
- `sync_config` writes a profile's `.claude.json` only while no `claude` process runs with that profile, because a running session holds the MCP servers and onboarding keys in memory; only keeping an outside preference key was checked. `cmd_update` checks with `in_use`, and so does `cmd_delete`, because a running session writes its files back into a deleted folder. `prefs` is the exception: it writes the keys in `account-prefs.json` while sessions run, because a running session keeps a key written to its `.claude.json` from outside (checked on 10-10-2026 with Claude Code 2.1.296). To check that with the installed version, while a session runs with `~/.claude.json`:
  1. Add a probe key: `t=$(mktemp ~/.claude.json.XXXX) && jq '.zzProbe=1' ~/.claude.json > $t && chmod 600 $t && mv $t ~/.claude.json`.
  2. Use the session until `stat -c %y ~/.claude.json` shows a newer time, which means the session wrote the file.
  3. `jq .zzProbe ~/.claude.json` prints `1` when the session kept the key. If it prints `null`, `prefs` must skip accounts in use, as `sync_config` does.
  4. Remove the key the same way with `jq 'del(.zzProbe)'`.
- Before linking, `cmd_update` moves the files of a profile's own copy of a shared folder into `~/.claude` with `fold_dir`, also only while no session runs with that profile. A file `~/.claude` already has keeps its copy, and the profile's copy stays in `<folder>.unmerged` inside the profile.
- `sync_config` copies three things from `~/.claude.json`: `mcpServers`, the onboarding keys, and every folder with `hasTrustDialogAccepted`. Then it writes the values in `account-prefs.json`, so a new account starts with them. `claude auth login` leaves the onboarding keys unset, and without them the first interactive start reruns the first-run wizard, which asks for a login method again.
- Delete runs `rm -rf` on the profile folder. `rm` removes the symlinks and never follows them, so `~/.claude` is untouched.
- A claude-desktop-extra profile NAME runs Claude Code in `~/.claude-NAME`, so an account with a desktop profile keeps its folder equal to its name. After renaming such an account, run `claude-desktop --delete-profile=OLD`, move `~/.config/Claude-OLD` to `~/.config/Claude-NEW`, and run `claude-desktop --create-profile=NEW`.
- A write through the `settings.json` symlink keeps the link. This was checked on 26-09-2026 with Claude Code 2.1.283 by changing a setting with `/config` in a profile. Recheck it after a major Claude Code update: `list` shows `broken` in the Links column when a link was replaced.

## Changing the code

1. Edit `src/claude_tools` or `libexec/`. When the `claude` function needs new behaviour, add a command and call it from `share/claude-tools.sh`; keep paths and names out of the shell config.
2. Run `nix fmt` from the repository root. It runs ruff with `ruff.toml` on `src`, and shellcheck with `.shellcheckrc` on `libexec`, `share` and `tests` (`tooling.nix`), and exits non-zero on a finding. The package build runs every command's `--help` and `bash -n` on the shell files.
3. Deploy, then run the commands against the real accounts. A change to `accounts` is done when every one of these holds:
   - `claude-tools accounts list` shows every account with its email and `ok` links.
   - `claude-tools accounts update` prints `config: synced` for each profile with no running session and exits 0.
   - `add tmp-x </dev/null`, then removing one link in `~/.claude-tmp-x`, makes `list` show `broken` for it; `delete tmp-x --yes` then removes the folder.
   - Replacing the `file-history` link in `~/.claude-tmp-x` with a real folder that holds one new file and one file `~/.claude/file-history` already has, then `update`, moves the new file, keeps the other in `file-history.unmerged`, and restores the link. `delete tmp-x --yes` refuses while a process named `claude` runs with `CLAUDE_CONFIG_DIR=$HOME/.claude-tmp-x`.
   - While that process runs, `rename tmp-x tmp-y` writes `tmp-y` into the marker, `names` and `dir tmp-y` use `tmp-y`, and `add tmp-x </dev/null` creates `~/.claude-tmp-x-2` for a new `tmp-x`. With the process stopped, `rename tmp-y tmp-z` moves the folder to `~/.claude-tmp-z`.
   - In a terminal, `claude --account <profile> auth status` prints that account's email, and `claude --account <main name> auth status` the main account's, and `claude --account nope` fails with `no account 'nope'`.
   - `login-all --list` prints exactly the accounts that the cards show as missing, logged out or ending within 5 days. After a change to `login`, log in to one account with it and check that the Brave profile from accounts.json opened and that `list` shows the expected organization.
   - The cards render in a terminal: `tmux new-session -d -s cpt -x 110 -y 40 claude-tools accounts --watch`, then `tmux capture-pane -p -t cpt` shows one card per account and a login line per host.
4. Land the change on nixos-config `main` (`AGENTS.md`).

## Tests

The end-to-end tests in `tests/` run on devbox against real Claude accounts and a real herdr server, each in its own herdr session or tmux server. Run them from a nixos-config checkout against the installed command, for example `pkgs/claude-tools/tests/orch-e2e.sh "$(dirname "$(readlink -f "$(command -v claude-tools)")")"`; each prints `PASS` and exits 0.

- `limit-switch-e2e.sh`: a switch held back while every other account is held, a switch, a scan that leaves an agent without a limit alone, a scan that holds and moves an agent whose screen shows a limit message, a scan that holds nothing after an old one, the restore after a server stop, and `resume`.
- `rotate-e2e.sh`: the account picker, the exit codes of `rotate`, a move after a limit, the wait while no account is free, and a prompt typed during that wait.
- `orch-e2e.sh`: `agent start`, `agent stop`, `agent peek`, `orch notify`, `orch watch`, and a watcher that replaces another one or refuses next to a foreign lock holder.

The picker step reads a usage cache and a hold file that the test writes from the real cache with changed numbers, so it proves how the picker shows and orders those records, not how `usage` and `rotate` write them. The move and wait steps write the hook's flag file themselves, with a made-up session limit message, on accounts that have room, so they prove the hold, the account choice after a fresh reading, the wait and the resume, not the hook or a real limit. The limit-switch scan steps ask the agent to print a made-up limit message, so `scan` reads it off the real screen, but no real limit stands behind it.

The dotfiles checkout's `desktop/bin/tests/desktop-sync-e2e.sh` runs the installed `claude-tools accounts prefs` and `config-lock.sh` against scratch homes, so a change to either needs that test too: `~/Desktop/workspace/dotfiles/desktop/bin/tests/desktop-sync-e2e.sh` after the deploy.

No test covers these, because a run cannot reach them for real:

- a move after a real usage limit, in `rotate` and `limit-switch`, with the session's memory kept across the move;
- the hold after a limit message without a reset time, such as a model limit, which reads the account's windows;
- the StopFailure hook handshake of `rotate`, including a nested `claude -p` whose limit must leave the session alone;
- `agent start`'s cleanup when herdr refuses the brief;
- the lock release of `prefs` and `update` when TERM ends them.
