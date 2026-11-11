---
name: worktrees
description: Creates, finishes, and removes git worktrees with worktrunk (wt) in the one layout every agent uses. Use before editing in a repository, before creating, landing from, abandoning, or removing a worktree, when starting subagents with worktree isolation, and when checking out another revision for a review or a deploy.
---

# Worktrees

Every editing task runs in its own worktree, and the main checkout is for reading and landing. Every worktree lives at `~/Desktop/workspace/worktrees/<repo>/<branch>`, where each `/` in the branch name becomes `-`: branch `fix/cart-total` of gastrodili sits in `~/Desktop/workspace/worktrees/gastrodili/fix-cart-total`. worktrunk's config (`~/.config/worktrunk/config.toml`, from nixos-config `home-manager/modules/agent-cli.nix`) holds that path, so `wt` puts it there for you.

The `guard-main-edit` hook refuses Edit, Write, and NotebookEdit in Claude Code in a main checkout. A repository whose own tooling needs its main checkout opts out with `git config agents.mainCheckoutEdits true`. `git config agents.mainCheckoutEditPaths <folder>/` opts out one folder only; nixos-config's `agents-pull` unit sets it to `agents/`, the folder its `agents/README.md` says to edit in the main checkout. A shell command that writes a file passes the hook, so the rule binds those too.

## Create

1. Name the branch `<type>/<slug>` with a Conventional Commit type, such as `fix/cart-total` or `docs/deploy-path`.
2. From the main checkout:

   ```sh
   git fetch origin
   wt switch --create fix/cart-total --base origin/main --no-cd --format=json
   ```

   The JSON's `path` is your worktree. `--base @` starts from the checkout's current commit instead. When the repository has an `.envrc`, the pre-start hook runs `direnv allow` and loads the devenv shell, so the devenv git hooks exist before the first commit. When that load fails, `wt` exits non-zero and prints no JSON, but the worktree exists at its layout path; fix the error, then run `direnv exec <path> true`. A `wt switch pr:<n>` worktree skips that step, because the pull request's `.envrc` and `devenv.nix` would run before anyone read them: read them, then run `direnv allow <path>`.
3. Work under that path. Each Bash call starts outside it, so begin a command with `cd <path> &&`, and run a repository tool as `cd <path> && direnv exec . <command>`.

Done when `git -C <path> branch --show-current` prints the branch.

A review or a deploy of another revision uses a detached worktree, which has no branch to clean up:

```sh
git worktree add --detach ~/Desktop/workspace/worktrees/<repo>/review-<sha7> <sha>
git worktree remove ~/Desktop/workspace/worktrees/<repo>/review-<sha7>
```

Name a detached worktree `<purpose>-<sha7>`, such as `review-<sha7>` or `deploy-<sha7>`, and remove it when the review or deploy ends.

## Finish

Land the change the way the repository's rules say. `pr-land <n>` removes the worktree and its branch once the PR merges. When the change goes straight to the default branch, as in nixos-config, remove the worktree yourself once the push is on the remote:

```sh
wt -C <main checkout> remove --reap --foreground <branch>
```

Stop each server or watcher you started there before the removal. The pre-remove hook runs `devenv down` for a running `devenv up`, and `--reap` stops the processes still running in the folder. `--reap` finds them with `lsof` and gives it 5 seconds. On nixos-desktop `lsof` took 0.3 s to 24 s in 15 runs, because it stats every open file of every process, so `--reap` often reports `No processes to reap` and leaves them running. Without `-D`, `wt` deletes the branch only when its changes are in the default branch, so a branch it keeps is unlanded work: go back and land it. A fix branch you merged into a receiving branch (an integration branch or a PR's branch) is the exception, as `~/.claude/shared/git.md` (Several issues or findings in one run) says: remove it right after the `git merge` succeeds, before the receiving branch is rebased, squash-merged, or deleted, with `wt -C <main checkout> remove --reap --foreground -D <fix branch>` and no archive tag. When the cleanup comes after the receiving branch landed, `wt list --branches` shows `⊂` for a fix branch the default branch holds, and `wt remove` without `-D` deletes it.

Done when `git worktree list` no longer shows the path, the folder is gone, and `git branch --list <branch>` prints nothing.

## Stop without landing

When the task ends with work that will not land now, because it was abandoned, superseded, or ran out of time:

1. Commit every uncommitted file on the branch. The worktree is yours alone, so `git -C <path> add -A` takes nothing from another session: `git -C <path> add -A && git -C <path> commit -m "wip: <the state it is in>"`.
2. Tag the commit locally: `git -C <path> tag archive/<branch>`. The tag stays on this host; never push it.
3. Remove the worktree and the branch: `wt -C <main checkout> remove --reap --foreground -D <branch>`.
4. Name the tag in the final message.

To pick the work up again, run `wt switch --create <branch> --base archive/<branch> --no-cd`, then `git tag -d archive/<branch>`.

## Keep

Keep a worktree only while Omer must decide about it, while a conflict waits for its owner, or when the archive commit's hook fails. The final message names its path and the reason, and the run's `TASKS.md` gets an open line for it.

## Subagents

The session that starts subagents removes every worktree they made before its final report. Claude Code's `WorktreeCreate` hook, which nixos-config's `programs.worktrunk.claudeCodeIntegration` installs, makes the worktree of an `isolation: "worktree"` agent with `wt switch --create <name>`, so it starts from the default branch, not from your commit, on a branch named after the agent; a name whose branch already exists fails. When the agent finishes, Claude Code keeps that worktree and its branch, with or without changes, does not run the `WorktreeRemove` hook, and names the path as `worktreePath:` in the Agent result. So for each one:

- No changes, when `git -C <path> status --short`, and `git log --oneline HEAD..<branch>` run from your own checkout, print nothing: `wt -C <main checkout> remove --reap --foreground -D <branch>`.
- Changes: land them through Finish, or use Stop without landing or Keep.

The `WorktreeRemove` hook runs only for the session's own worktree (`claude --worktree`), when Omer picks remove at exit or `ExitWorktree` discards it; it runs `wt remove --force` on that worktree, which removes it with any uncommitted changes and deletes the branch only when the default branch holds it. The sweep removes a forgotten agent worktree a day later only when its branch is already in the default branch.

## devenv in a worktree

- A process with `ports.<name>.allocate` takes the next free port, so `devenv up` runs in several worktrees at once.
- `.devenv/` belongs to each worktree, so the first `direnv exec` in a new one evaluates the shell again.
- After a removal, the worktree's `.devenv/gc` roots point at nothing, and Nix garbage collection drops them.

## Sweep

`worktree-sweep.timer` runs `wt step prune` once a day in each repository under `~/Desktop/workspace`. It removes each worktree and branch that is merged into the default branch, clean, and older than a day, which includes a detached worktree whose commit is in the default branch and a local branch without a worktree, and lists the worktrees it kept in `/tmp/agents/worktree-sweep/report.md`. Unmerged and dirty worktrees stay for their owner, so the sweep does not replace Finish. A failed run prints a `worktree-sweep:` line at each shell start until a run succeeds.
