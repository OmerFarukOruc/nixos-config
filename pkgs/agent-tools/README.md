# agent-tools

The commands the agent rules name, in one package that `home-manager/modules/agents.nix` installs on nixos-desktop, nixos-rog and devbox. Each command prints its usage with `--help` or the comment at its top.

## Commands

- `pr-land` waits for the base branch's required checks, asks Pullfrog once for a review when its check cannot arrive on its own, squash-merges a PR, and removes its worktree, local branch, and remote branch when each tip equals the PR head. The daily `worktree-sweep.timer` removes older merged local worktrees and branches, and GitHub deletes a merged PR's remote branch where the repository turns on `delete_branch_on_merge`. Run `pr-land --help` for the rules.
- `removed-defs <base> <head>` lists what a diff removes from Python files by name (tests, helpers, module-level names, dropped parametrize cases) and prints the few changes that still need a read. With `--ids <file>` it compares the removed tests with a list.
- `wait-exit [--pid <pid>] <log> <seconds>` waits until a log ends with the `exit N` line that `cmd > log 2>&1; ec=$?; echo "exit $ec" >> log; exit $ec` appends, prints a progress line at each check that does not end the wait, and exits N, or 124 at the first check at or after the deadline, or 125 once `ps -p` no longer finds the `--pid` process and the log's last line is not an exit line. With `--pid`, an exit line counts only once that process is gone.
- `dryer [options]` runs unclebob/dryer at a pinned commit over the whole repository at a 0.8 threshold and keeps its `.metrics/dry.edn` out of the repository. It reads the Clojure, Java, Go, TypeScript, JavaScript, Rust, and Python files git lists, tracked or untracked and not ignored. The package builds dryer, so a sandboxed agent needs no network to run it.
- `path-claims PATH...` lists the other worktrees of the current repository whose uncommitted changes or commits not on `origin/main` touch PATH, with the Claude Code or Codex sessions whose tool output shows `wt` creating each one, and exits 3 when it finds one.
- `codex-ask [--model <model>] [--effort <level>] [--search] <advise|review|plain> <checkout> <brief-file> <out-dir>` starts a read-only Codex consult or review (gpt-6.1-sol at medium by default) detached and returns at once, because a subagent may not use the Bash tool's `run_in_background` and a foreground call ends at the tool's 600 s limit; `code-reviewer` runs the review beside its own, and the consult rule in `agents/shared/core.md` (Working) runs the advise mode, and quality-campaign's council runs the plain mode. The answer goes to `<out-dir>/answer.md`, and `<out-dir>/status` gets the `exit N` line that the `wait-exit` command it prints waits for.
- `gh-issue-tree <owner/repo> <number> <dir>` saves a GitHub issue, its comments, and its sub-issues as Markdown files.
- `cc-setting KEY...` says whether Claude Code keeps a setting as a `settings.json` key, an environment variable, or a per-account preference in `~/.claude.json`, and lists the environment variables whose names contain KEY.
- `oom-report [--since TIME] [--all]` summarizes the latest kernel OOM incident from the journal: what the kernel killed, the processes in its task table by name, the units that stopped with their memory and swap peaks, and the Claude sessions that wrote during the incident and then went quiet, with their resume commands. Some of those may only be idle.
- `brave-browser` runs agent-browser against Omer's Brave: this host's Brave Origin, found by `brave-cdp`, or with `--on <machine>` the Brave that machine lends with `browser-lend`, found by `lend-cdp`.
- `infisical-describe` lists Infisical records without a description and writes one; `agents/infisical.md` says when to run it.
- `agent-watch NAME REPORT SECONDS` waits for a named Claude Code subagent's report file and exits 3 early, with the agent's last answer, when the agent ended its turn without writing it.
- `gh-wait-checks <owner/repo> <sha> <seconds> [name-regex ...]` waits until every GitHub check run on a commit has completed and exits with their verdict.
- `cdp-eval EXPRESSION URL...` loads pages in a headless Chromium-family browser with a fresh profile and prints what a JavaScript expression returns on each.
- `sandbox-run [--rw PATH]... [--ro PATH]... [--] CMD` runs one command in a bubblewrap sandbox that sees no host process, network, or user socket.

## Build and check

- `pkgs/agent-tools.nix` copies `bin/` as it is. A bash command runs with this package's commands and git, gh, jq, curl, bubblewrap, glow, less and the coreutils-style tools first on `PATH`. `wt`, `codex`, `tailscale`, `agent-browser`, `herdr`, `infisical` and the desktop tools that `ropen` opens still come from the caller's `PATH`. A Python command uses the standard library only.
- `dryer` runs `unclebob/dryer` at the commit `pkgs/agent-tools.nix` pins, built with the tree-sitter packages from nixpkgs. To move the pin, change `rev`, set `hash` to `lib.fakeHash`, and take the hash the build prints.
- Prove a change with `scripts/build.sh pkgs/agent-tools.nix`, then run the changed command from the printed store path. `tests/sandbox-run-e2e.sh <store path>/bin/sandbox-run` checks `sandbox-run`'s binds.

## Lend a browser

`browser-lend` (Linux and macOS) and `share/browser-lend.ps1` (Windows) let agents on `devbox` drive a logged-in Brave, Chrome, Chromium, or Edge on any tailnet machine. On a machine without this package, copy the one file there.

1. In the browser, open `<browser>://inspect/#remote-debugging` (for example `brave://inspect/#remote-debugging`) and turn remote debugging on.
2. Run `browser-lend on` on Linux or macOS, or `powershell -ExecutionPolicy Bypass -File browser-lend.ps1 on` on Windows. It prints the exact command for the agent on the box. When several browsers are open, add a name to pick one, for example `browser-lend on chrome`.
3. When the agent first connects, click Allow in the browser.
4. Run `browser-lend off` (on Windows, `browser-lend.ps1 off`) when the task is done. While it is on, any process under `omer` on the box can drive that browser.

## Read remote files

Omer works on devbox from nixos-desktop or nixos-rog through herdr (`herdr --remote omer@devbox`), so the paths agents print, such as `/tmp/thermo-review/thermo-b9b14ec.md`, are on the box. He reads them in one of three ways:

- **In herdr**, on either host: `mdv FILE.md` opens the file rendered by glow in a new herdr tab next to the current pane, in `less`, so `/` searches and `q` closes the tab. `mdv DIR` opens glow's file browser for the folder. In a Claude Code session, type `! mdv FILE.md`.
- **In VS Code** on nixos-desktop or nixos-rog: `ropen PATH` opens the file over Remote-SSH. The editor shows the live file, so it updates while an agent writes it. A markdown file opens in the preview (`workbench.editorAssociations` in nixos-config `home-manager/modules/vscode.nix`), `PATH:LINE` opens another file at that line, and a folder opens as a workspace. To follow a review's `file:line` references, run `ropen ~/Desktop/workspace/<repo>` first: the report then opens in that window, and Ctrl+P takes a `file:line`. The first connection installs VS Code's server in `~/.vscode-server` on the box. `ropen` and Remote Explorer both connect through the `Host devbox` entry (`User omer`) in `~/.ssh/config`, which `nixosModules/ssh-hosts.nix` links on nixos-desktop and nixos-rog to the `ssh-config` key of `secrets/workstations.yaml`; edit the hosts there with sops ([Secrets](../../docs/nixos-rog.md#secrets)), and the next switch reaches both machines.
- **In Dolphin** or any other local app: nixos-config's `home-manager/modules/sshfs-devbox.nix` keeps the whole box mounted read-only, and `/tmp/x` on the box is `~/remote/devbox/tmp/x` here. `ropen -f PATH` opens Dolphin with the file selected, or the remote home without PATH. Edit the box's files in VS Code, because the mount refuses writes.

Without PATH, `ropen` takes the path from the clipboard and drops the backticks or quotes around it, so a path copied from a herdr pane opens with no typing. `ropen` starts the mount when it is down, because both modes check the path through it.
