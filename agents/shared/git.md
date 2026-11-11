# Git: history, landing, and multi-fix runs

`core.md` (Git) holds the worktree, commit, and delivery rules.

## History and bisect

- Edit history with `git rebase` in your own worktree. `git history` is experimental in 2.56, runs no hooks, and by default rewrites every descendant branch, including other sessions' branches. Rebase and push with `--force-with-lease` and nothing else, because the reflog and the remote's history already hold the replaced head; the `archive/<branch>` tag in `core.md` (Git) is only for unlanded work. Bad: `git tag archive/<branch>-pre-rebase` and a rollback command in the report. Good: rebase, push, and name the new head.
- On Git 2.56 or newer, run `git bisect run --reset-when-found` so a bisect never leaves the shared checkout in bisect state.

## Landing a PR

- `pr-land --after <m> <n>` waits for PR `<m>` to merge first. Where `.github/workflows/merge-controller.yml` exists, `pr-land` adds the `automerge` label and waits for that workflow to squash-merge once the `gate` check is green; elsewhere it squash-merges directly. Once the PR is MERGED, it removes the worktree, local branch, and remote branch whose tip equals the PR head, whoever made them. The daily `worktree-sweep.timer` (`wt step prune`) removes older merged local worktrees and branches, and GitHub deletes a merged PR's remote branch in each repository that turns on `delete_branch_on_merge`. Run `git worktree list` first. If a worktree that is not yours has the PR's head branch checked out, ask its owner (the orchestrator in an orchestrated run) before running the command; when nobody can answer, leave that branch alone and report it. Exit 3 means `pr-land` stopped or kept something and printed why (`pr-land --help` lists the causes); settle every exit 3 before you report done, rerun `pr-land <n>` when it reports a changed head, and report a cause you cannot settle. Without `pr-land`, run `gh pr merge --squash` only where `.github/workflows/merge-controller.yml` does not exist; where it exists, stop and tell Omer, because a direct merge skips the `gate` check and only Omer adds the `automerge` label by hand. If `gh pr merge` exits 1, check MERGED with `gh pr view <n> --json state,mergeCommit` before a rerun. Only once the PR is MERGED, remove the worktree, delete the local branch with `-D`, delete the remote branch if it survived, and run `git fetch --prune`.

## Several issues or findings in one run

- In a multi-issue campaign, each issue gets its own worktree and one focused commit; post the evidence and confirm the remote SHA before closing it or moving on.
- When one session fixes several findings of one task that are not separate tracked issues (those follow the campaign rule above), give each fix its own worktree and branch, merge it locally into one integration branch once its gate passes, and then remove that fix's worktree and branch with `-D` and no archive tag, because the integration branch now carries its commits and `wt` deletes without `-D` only a branch the default branch already holds. Run the cleanup pass (`/simplify` in Claude Code) on the integration branch, then its one review, then deliver it by the delivery workflow in `core.md` (Git), as one PR when that workflow needs a PR, because a failing fix stays out of the others and the review sees the combined landing shape once.

## Missing files

- Before reporting a file missing, check path variants such as a dropped extension and `git stash list`.
