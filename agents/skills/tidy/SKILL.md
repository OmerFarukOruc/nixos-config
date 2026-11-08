---
name: tidy
description: Clean up changed code without changing behavior, with the review sized to the diff and a verification run after the fixes. Use when the user invokes /tidy, asks to simplify or refine recent changes, wants post-implementation cleanup or pre-PR polish, or asks for quality-only cleanup focused on reuse, simplification, efficiency, and altitude issues. This is not a bug hunt; use code-review for correctness review.
---

# Tidy

`/tidy` runs four cleanup passes, yourself or, for a large diff, in four parallel agents, then applies the fixes.

You are improving the quality of the changed code, not hunting for bugs. Review it for reuse, simplification, efficiency, and altitude issues, then fix what you find. Do not look for correctness bugs; that is what `/code-review` is for.

## Phase 0: Gather The Diff

Run `git diff @{upstream}...HEAD` (or `git diff main...HEAD` / `git diff HEAD~1` if there is no upstream) to get the unified diff under review. If there are uncommitted changes, or the range diff is empty, also run `git diff HEAD` and include the working-tree changes in scope. The review often runs before the commit.

If a PR number, branch name, file path, or focus was passed as an argument, review that target instead. Treat this diff as the review scope.

## Phase 1: Review

Count the changed lines of code: the added plus deleted lines from `git diff --numstat` for every file except Markdown (`*.md`). Run the four passes below yourself, in turn. At 150 or more, when reading the diff with the code around it would fill much of your context, launch four review agents in parallel instead, one angle each. Give each agent the diff command, the changed-file list, and its angle. Do not paste the full diff unless needed.

Each pass reports only on lines the diff adds or changes; a problem in code the diff leaves untouched is out of scope. Each finding has:

- `file`
- `line`
- `summary`
- `cost`: what is duplicated, wasted, or harder to maintain

### Reuse

Flag new code that re-implements something the codebase already has. Search shared/utility modules and files adjacent to the change, and name the existing helper to call instead.

### Simplification

Flag unnecessary complexity the diff adds: redundant or derivable state, copy-paste with slight variation, deep nesting, or dead code left behind. Name the simpler form that does the same job.

### Efficiency

Flag wasted work the diff introduces: redundant computation or repeated I/O, independent operations run sequentially, blocking work added to startup or hot paths.

Also flag long-lived objects built from closures or captured environments. They keep the entire enclosing scope alive for the object's lifetime, which can become a memory leak when that scope holds large values. Prefer a class, struct, or plain data object that copies only the fields it needs. Name the cheaper alternative.

### Altitude

Check that each change is implemented at the right depth, not as a fragile bandaid. Special cases layered on shared infrastructure are a sign the fix is not deep enough. Prefer generalizing the underlying mechanism over adding special cases.

## Phase 2: Apply The Fixes

Wait for every pass to complete. Deduplicate findings that point at the same line or mechanism, then fix each remaining one directly.

Skip any finding whose fix would change intended behavior, require changes well outside the reviewed diff, or that you judge to be a false positive. Note the skip rather than arguing with it.

## Phase 3: Verify And Report

Run focused verification for the files or behavior you changed. Prefer targeted tests, lint, typecheck, build, or smoke commands that cover the touched code.

Finish with a brief summary of what was fixed and what was skipped, or confirm the code was already clean. Include the verification command and result. Say whether you ran the passes yourself or in agents. This cleanup is not the change's review.
