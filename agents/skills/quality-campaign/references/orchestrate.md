# Orchestrate route

Outcome: every slice implemented, reviewed, and merged into an integration branch; the campaign landed on the default branch; every issue closed with evidence; every worktree and branch cleaned up. You are orchestrator and reviewer. Writers write the code and commit in their worktrees. You merge; you never commit slice code.

## 1. Preflight

- Read the parent issue and every subissue.
- Rebuild the dependency graph from native blocked-by metadata. Then recompute same-file collisions from each subissue's declared file lists. Re-derive; do not just trust: the live trial found a real edge the metadata never had.
- Check the writer binding with `--help`. Measure machine headroom: cores, free RAM, disk.
- Create the integration branch off the default branch. Record the baseline SHA.
- Write the dispatch and resume wrapper scripts once. Never vary the invocation shape afterward: a cosmetic `cd` plus `set -e` wrapper around the same command once stalled a writer for six hours on stdin, with no error.
- Present the plan for approval before the first dispatch.

## 2. Dispatch

One slice: one worktree, one branch off the integration head, one writer.

- Worktrees live in a sibling directory outside the repo.
- When a slice needs an installed dependency tree (node_modules or similar), copy it into the worktree. A symlink lets the writer mutate the main checkout.
- Prepend an orchestrator preamble to the issue body. It tells the writer:
  - You are already in the worktree on the right branch.
  - Never push, merge, rebase, or open a PR.
  - Never comment on GitHub; the orchestrator posts there.
  - Commit with the plan's subject when done.
  - Your final message states the commit SHA, the files changed, and the actual output of every Done-criteria command.
- Stagger launches. Before each new batch, measure free RAM, load, and per-writer memory. Hold dispatch while the machine is saturated.
- Point writer caches and long verification runs at real disk, not tmpfs. Track what writers leave under `/tmp` and clean it: in the live trial, leftover caches exhausted the tmpfs quota and broke `git push` and the orchestrator's own shell at once.
- Comment the writer's session id on the subissue immediately: model, effort, sandbox, worktree, branch.
- Slices touching the same files stay serial. A blocked slice waits until its native edges close.

## 3. Review loop, per slice

1. Re-run the issue's Done-criteria commands yourself in the worktree, with cache-busting flags. A from-cache result proves nothing. Never merge on the writer's self-report.
2. Load the standards-spec-review skill and run it on the slice branch against its merge base with integration, judged against the subissue. Review subagents work read-only and run no builds while writers run.
3. On failure: write a verdict file with the findings and resume the writer with it. When it reports, check its fixes yourself with `git range-diff` between the reviewed and the fixed branch; start no second review.
4. On a STOP condition or scope exception: verify the writer's claim independently. Override only with evidence, recorded in a verdict file, expanding scope by the minimum, normally a single file.
5. Regression fixes follow the "Bug fixes" rule in `~/.claude/shared/testing-discipline.md`, so a writer repairs the existing test that should have caught the bug before adding one. Then apply the mutation bar: revert the fix, confirm the test's assertion fails after setup succeeded, restore, confirm it passes. A green suite alone is not proof.
6. Merge `--no-ff` into integration with a commit message that lists what you verified. Then confirm the branch tip actually advanced: a merge on a detached HEAD succeeds silently.
7. Run the full test and policy suite on integration after every merge. Slice-local gates missed three cross-cutting breaks in the live trial.
8. Close the subissue with a Check, Command, Result table.

Failure attribution: before blaming a failure on the campaign, reproduce it in a same-commit baseline worktree of the default branch. Re-run transient infrastructure failures, such as port collisions between concurrent test runs, serially before any verdict.

A regression traced to a closed slice: fix it through the normal cycle, then comment the fix commit and evidence on the closed issue. Do not reopen.

Escalate to the user when a fix trades one failure mode for another. Abandoning a slice with a recorded reason and a follow-up issue is a normal outcome.

## 4. Endgame

After the last slice merges:

1. Full verification sweep on integration: every suite the repo has.
2. If the repo has an end-to-end verification script, run it on the user's request. Attribute every failure through the baseline worktree; file a fresh issue for each pre-existing defect. Watch for scripts that mutate the invoking clone's git state: a shallow fetch inside a verify script truncated the dev clone's history in the live trial.
3. If any slice restructured build inputs, build the container images too. Unit gates do not cover image builds.
4. Hardening passes over the full campaign diff, on the user's request: the internal deep review, then `/tidy`. Every finding takes the necessity test; accepted fixes follow the slice cycle.
5. Push and open a PR only on explicit authorization, so CI and external PR reviewers run. Treat the external PR review as a second gate: the live trial's only escaped regression was caught there, by no internal gate.
6. Squash-merge on explicit authorization. Sync local. Close the parent with the full evidence ledger: gate results, abandoned slices with reasons, defects fixed, defects filed as follow-ups, findings deliberately not fixed.
7. Cleanup: scan every worktree for uncommitted work before removing it. Before deleting any branch, confirm its commits stay reachable elsewhere; the integration branch or the PR head ref is the pre-squash audit trail.
8. Late trivial fixes may take the hygiene path: a direct commit is allowed, but it still gets a tracking issue, a push, and a remote-landing check. Everything else follows the slice cycle.
9. The campaign is closed only when local and origin agree on every ref you touched. Nothing may exist only on this machine.
10. Propose skill and bindings edits from this campaign's lessons. The user decides.
