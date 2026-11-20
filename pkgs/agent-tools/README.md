# agent-tools

The commands the agent rules name, in one package that `home-manager/modules/agents.nix` installs on nixos-desktop, nixos-rog and devbox. Each command prints its usage with `--help` or the comment at its top.

## Commands

- `pr-land` waits for the base branch's required checks, squash-merges a PR, and removes the worktree, local branch, and remote branch it leaves behind. `pr-land --help` prints the commands, exit codes, and variables, and [How `pr-land` decides](#how-pr-land-decides) gives the rules.
- `removed-defs <base> <head>` lists what a diff removes from Python files by name (tests, helpers, module-level names, dropped parametrize cases) and prints the few changes that still need a read. With `--ids <file>` it compares the removed tests with a list.
- `wait-exit [--pid <pid>] <log> <seconds>` waits until a log ends with the `exit N` line that `cmd > log 2>&1; ec=$?; echo "exit $ec" >> log; exit $ec` appends, prints a progress line at each check that does not end the wait, and exits N, or 124 at the first check at or after the deadline, or 125 once `ps -p` no longer finds the `--pid` process and the log's last line is not an exit line. With `--pid`, an exit line counts only once that process is gone.
- `dryer [options]` runs unclebob/dryer at a pinned commit over the whole repository at a 0.8 threshold and keeps its `.metrics/dry.edn` out of the repository. It reads the Clojure, Java, Go, TypeScript, JavaScript, Rust, and Python files git lists, tracked or untracked and not ignored. The package builds dryer, so a sandboxed agent needs no network to run it.
- `path-claims PATH...` lists the other worktrees of the current repository whose uncommitted changes or commits not on `origin/main` touch PATH, with the Claude Code or Codex sessions whose tool output shows `wt` creating each one, and exits 3 when it finds one.
- `wait-until <clock time>` waits until a full date and time such as `YYYY-MM-DDTHH:MM:SSZ`, or other text with a digit that `date -u -d` reads (a bare time of day is UTC), prints a progress line every 300 s (`WAIT_UNTIL_STEP` sets the seconds), and exits 0 at the target, not up to one step after it; a time already passed ends it at once with a line that says so, and bad arguments exit 2.
- `codex-ask [--model <model>] [--effort <level>] [--search] <advise|review|plain> <checkout> <brief-file> <out-dir>` starts a read-only Codex consult or review (gpt-6.2-astra at medium by default) detached and returns at once, because a subagent may not use the Bash tool's `run_in_background` and a foreground call ends at the tool's 600 s limit; `code-reviewer` runs the review beside its own, and the consult rule in `agents/shared/core.md` (Working) runs the advise mode, and quality-campaign's council runs the plain mode. Where the host has `heavy` (nixos-desktop and nixos-rog), Codex runs through it, in a capped scope of its own unless `HEAVY_ACTIVE` is already set, which keeps a runaway Codex command out of the caller's cgroup: on 2026-11-08 a Codex review ran `rg --files -L` over `/nix/store`, grew to 17 GiB, and the OOM kill in herdr's shared `herdr-default.service` cgroup (`MemoryMax` 20 GiB) also killed two Claude sessions (`oom-report`). The answer goes to `<out-dir>/answer.md`, and `<out-dir>/status` gets the `exit N` line that the `wait-exit` command it prints waits for.
- `gh-issue-tree <owner/repo> <number> <dir>` saves a GitHub issue, its comments, and its sub-issues as Markdown files.
- `cc-setting KEY...` says whether Claude Code keeps a setting as a `settings.json` key, an environment variable, or a per-account preference in `~/.claude.json`, and lists the environment variables whose names contain KEY.
- `oom-report [--since TIME] [--all]` summarizes the latest kernel OOM incident from the journal: what the kernel killed, the processes in its task table by name, the units that stopped with their memory and swap peaks, and the Claude sessions that wrote during the incident and then went quiet, with their resume commands. Some of those may only be idle.
- `box-browser` runs agent-browser against this host's box browser, or devbox's, or with `--brave` against Omer's Brave on the same PC; `login-code` writes a sign-in code from the login-code mailbox to a 0600 file. [Agent browsers](../../docs/box-browser.md) describes all three.
- `infisical-describe` lists Infisical records without a description and writes one; `agents/infisical.md` says when to run it.
- `agent-watch NAME REPORT SECONDS` waits for a named Claude Code subagent's report file and exits 3 early, with the agent's last answer, when the agent ended its turn without writing it.
- `gh-wait-checks <owner/repo> <sha> <seconds> [name-regex ...]` waits until every GitHub check run on a commit has completed and exits with their verdict.
- `cdp-eval EXPRESSION URL...` loads pages in a headless Chromium-family browser with a fresh profile and prints what a JavaScript expression returns on each.
- `sandbox-run [--rw PATH]... [--ro PATH]... [--] CMD` runs one command in a bubblewrap sandbox that sees no host process, network, or user socket.

## How `pr-land` decides

`pr-land --help` prints the commands, the exit codes, and the variables. The rules behind them, and the reason for each:

The wait for checks:

- The required checks are the contexts of the base branch's protection and of its rulesets, because a ruleset check such as statuslantern's `gate` is absent from the protection endpoint, which answers 404 there. A required check that failed or was cancelled stops the merge.
- When that list is unreadable or empty, the PR's own checks decide, and a failed or cancelled one stops the run. `pr-land` merges without checks only after three polls in a row list none, because GitHub registers checks some seconds after a push. A failed lookup never counts as none.
- Each wait is bounded by wall-clock time, so the time of each read counts. The last sleep is cut to the time left, one more read follows, and the wait gives up right after it unless that read shows the checks done.
- Every 60 s and right before the merge it reads the PR again. A PR merged meanwhile goes on to the cleanup. A PR that is a draft when the wait starts, or that was closed, became a draft, got a new head, or was retargeted, ends the run with exit 3.
- The merge passes `--match-head-commit`, so GitHub refuses it when the head moved after the last read.

A PR behind its base, where the repository has no merge controller:

- Under the strict policy of branch protection or of a ruleset, GitHub refuses the merge with 'head branch is not up to date' or 'Head branch is out of date'. Right after another PR merges, `gh pr merge` has failed with a ruleset's 'N of N required status checks are expected' while `mergeStateStatus` read `BEHIND`.
- On that ruleset message, `pr-land` reads `mergeStateStatus`, up to five times 3 s apart while it reads `UNKNOWN`, and treats `BEHIND` like the out-of-date messages. Any other message or state is a failed merge. For a PR that is behind, `pr-land` calls the update-branch API with `expected_head_sha`, takes the new head only when its first parent is the old head, waits for the required checks on it, and merges again. It calls the REST endpoint because `gh pr update-branch` has no flag for an expected head, so only the REST call can pin the update to the head that `pr-land` waited on.
- Each updated head gets its own `PR_LAND_WAIT`. At most 3 updates run, and a fourth refusal is a failed merge (exit 1). A PR that gets another head, or is closed, while it waits ends with exit 3. A body given as `--body-file -` is read once for all tries.
- In controller mode the controller updates branches, so `pr-land` never does.

Merge controller mode:

- When the default branch has `.github/workflows/merge-controller.yml`, `pr-land` does not merge an open PR. It adds the `automerge` label and waits for the controller, and it refuses `gh pr merge` flags and a draft PR with exit 2.
- The default wait is 13200 seconds: the backend gate job's timeout (115 min), plus the p90 queue wait of the backend runners at busy hours (95 min, measured on 12-10-2026 before the new runner pool), plus the controller's 10-minute schedule.
- It reads the PR once per 60 s and the merge-pause issues once per 300 s. After 25 minutes it also checks every 10 minutes that the controller workflow completed a successful run after the label, or after `pr-land` started waiting when the label was already there.
- Exit 3 means nothing will merge the PR now. The causes are a changed PR head (the controller updated the branch for an overlap, and the gate reruns), a `gate` check on the current head that ended in FAILURE, CANCELLED, TIMED_OUT or ACTION_REQUIRED, an open merge-pause issue on a PR without `fixes-main`, a PR closed unmerged, a removed label, a PR made a draft or retargeted during the wait, a controller workflow with no successful run since then, and a PR that does not target the default branch, which the controller skips, so `pr-land` adds no label.
- When `pr-land` stops after it added the label, the label stays, so the controller still merges the PR once the cause is gone, and a rerun resumes the wait.
- A lookup of the workflow that fails for any reason but Not Found ends with exit 3 in every repository, because a direct merge would skip the controller's gate check. The default branch comes from the API, because `origin/HEAD` goes stale after a rename, and a repository without one ends with exit 3.

`--after <m> <number>`:

- It reads PR m once per 60 s for `PR_LAND_AFTER_WAIT` seconds. The default is the controller wait, since PR m may wait on the controller too. It exits 3 when PR m is closed unmerged and 1 when the wait runs out.
- A failed read is retried. A PR that cannot be read at the start stops the run with exit 1 before the wait, and a `<number>` that is closed stops it with exit 3.

Cleanup:

- A worktree, local branch, or remote branch goes only when its tip equals the head commit of the merged PR or is contained in it, so a reused branch name or a branch with later commits stays. A branch that any PR uses as its base, such as `dev` for a release PR, stays, and so does a branch that an open PR uses as its head. A fork PR has no branch to clean up.
- For a PR from the same repository, `pr-land` fetches `refs/pull/<n>/head` first, in both modes. A repository with `delete_branch_on_merge` loses the head branch at merge, and a head that a branch update made is then on no other ref; the fetch is harmless in a repository without that setting.
- The daily `worktree-sweep.timer` removes older merged local worktrees and branches, and GitHub deletes a merged PR's remote branch where the repository turns on `delete_branch_on_merge`.
- It fast-forwards the local base branch, also past local commits whose changes already landed through a squash merge.

A token without the Checks permission, such as a fine-grained personal access token:

- GitHub refuses it the PR's check rollup, `gh pr checks`, and the check-runs list (gh 2.103.3: the check-runs list answers HTTP 403 and the other two a GraphQL error, each 'Resource not accessible by personal access token').
- On that HTTP 403, `pr-land` reads a required Actions job from the newest Actions run of each workflow on the head, with a check run's pending, success and failure meaning. The controller wait reads the newest `gate.yml` run of the head, and the wait for the PR's own checks reads the newest run of every workflow on the head. A run still going is pending; success, neutral and skipped are green; every other conclusion is red; a failed read is retried and never green.
- A check that a GitHub App posts outside Actions, such as a Cloudflare build, stays invisible to such a token, and a wait for a required one ends at `PR_LAND_WAIT`.

## Build and check

- `pkgs/agent-tools.nix` copies `bin/` as it is. A bash command runs with this package's commands and git, gh, jq, curl, bubblewrap, glow, less and the coreutils-style tools first on `PATH`. `wt`, `codex`, `heavy`, `tailscale`, `agent-browser`, `herdr`, `infisical` and the desktop tools that `ropen` opens still come from the caller's `PATH`. A Python command uses the standard library only.
- `dryer` runs `unclebob/dryer` at the commit `pkgs/agent-tools.nix` pins, built with the tree-sitter packages from nixpkgs. To move the pin, change `rev`, set `hash` to `lib.fakeHash`, and take the hash the build prints.
- Prove a change with `scripts/build.sh pkgs/agent-tools.nix`, then run the changed command from the printed store path. `tests/sandbox-run-e2e.sh <store path>/bin/sandbox-run` checks `sandbox-run`'s binds.

## Read remote files

Omer works on devbox from nixos-desktop or nixos-rog through herdr (`herdr --remote omer@devbox`), so the paths agents print, such as `/tmp/thermo-review/thermo-b9b14ec.md`, are on the box. He reads them in one of three ways:

- **In herdr**, on either host: `mdv FILE.md` opens the file rendered by glow in a new herdr tab next to the current pane, in `less`, so `/` searches and `q` closes the tab. `mdv DIR` opens glow's file browser for the folder. In a Claude Code session, type `! mdv FILE.md`.
- **In VS Code** on nixos-desktop or nixos-rog: `ropen PATH` opens the file over Remote-SSH. The editor shows the live file, so it updates while an agent writes it. A markdown file opens in the preview (`workbench.editorAssociations` in nixos-config `home-manager/modules/vscode.nix`), `PATH:LINE` opens another file at that line, and a folder opens as a workspace. To follow a review's `file:line` references, run `ropen ~/Desktop/workspace/<repo>` first: the report then opens in that window, and Ctrl+P takes a `file:line`. The first connection installs VS Code's server in `~/.vscode-server` on the box. `ropen` and Remote Explorer both connect through the `Host devbox` entry (`User omer`) in `~/.ssh/config`, which `nixosModules/ssh-hosts.nix` links on nixos-desktop and nixos-rog to the `ssh-config` key of `secrets/workstations.yaml`; edit the hosts there with sops ([Secrets](../../docs/nixos-rog.md#secrets)), and the next switch reaches both machines.
- **In Dolphin** or any other local app: nixos-config's `home-manager/modules/sshfs-devbox.nix` keeps the whole box mounted read-only, and `/tmp/x` on the box is `~/remote/devbox/tmp/x` here. `ropen -f PATH` opens Dolphin with the file selected, or the remote home without PATH. Edit the box's files in VS Code, because the mount refuses writes.

Without PATH, `ropen` takes the path from the clipboard and drops the backticks or quotes around it, so a path copied from a herdr pane opens with no typing. `ropen` starts the mount when it is down, because both modes check the path through it.
