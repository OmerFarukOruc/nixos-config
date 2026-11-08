---
name: test-audit
description: "Runs a test-audit campaign over a repository's tests: baseline, lanes, a ledger mark for every test, keepers, cutover with caught mutations, and a preservation review. Use when asked to audit, prune, or clean up a test suite or one subsystem's tests, or to check that deleted or merged tests left no contract unproven."
disable-model-invocation: true
---

# Test audit

The rules come from `~/.claude/shared/testing-discipline.md`. Read it in full first; this skill holds only the order of work. The caller supplies the repository, the scope (the whole suite or one subsystem), the command that runs one test file, the full gate command, the landing workflow, and the agent budget. Ask for any of these the repository's `AGENTS.md` does not answer.

Keep the open items in `/tmp/agents/<task>-<session8>/TASKS.md`, one check per line, ticked only after its command ran. Each step ends on its completion criterion; start the next step only after it holds.

## 1. Baseline

Pin a SHA on the default branch. Regenerate every generated input the gate regenerates, then run every test file in scope and record its pass or fail. Count test lines and production lines separately.

When a test file fails here but passes in the gate, the harness differs from the gate, for example a generated file that the test helper rebuilds only when it is missing. Fix the harness first, in its own change, and take the baseline again on the merge commit. Keep the remaining failures in their own list: each may be a product bug, and a red test is never deleted for being red.

Done when every test file in scope has a recorded result at the pinned SHA.

## 2. Lanes

Split the scope into **lanes** along production owner areas, such as the sections of the repository's architecture document, not along file names. The shared test harness is one lane. The end-to-end scripts are one lane or belong to the lane of the area they check. Write the map to `$TMPDIR/<task>/lanes.json`.

Done when every test file and end-to-end script in scope belongs to exactly one lane.

## 3. Ledger

Give each lane to one read-only agent (prompt in [references/prompts.md](references/prompts.md), "Ledger agent"). It reads every test in the lane in full, the production owner each test reaches, its callers, its history, and how the gate runs it. Each test declaration gets one row in a **ledger** (`decl`, `name`, `mark`, `target`, `evidence`) with one mark:

- `R` retain: the contract and the regression it catches. A move to a better file stays `R`.
- `F` repair: the contract stays, the assertion or scenario changes, such as a negative test that passes at an unrelated guard.
- `C` consolidate: the named keeper that absorbs the assertion.
- `D` delete: the proof that remains, or why no contract exists.

A loop or table that declares many tests is one row unless its cases need different marks.

Done when a script that lists every declaration at the pinned SHA finds each one in a ledger with a mark and an evidence line.

## 4. Layer plan

A second read-only pass per lane starts from the ledger and looks for the redundant **layer**: a suite that replays a contract a stronger suite already proves. It names the **keeper** for each contract, preferring the real transport or store over a mocked collaborator, the assertions to carry into keepers, the files that go, and the test-only production seams the lane unlocks. It corrects ledger errors it finds.

Before you accept a lane, check a few rows of its ledger and plan against the source yourself. Agent claims about callers and seams are often wrong.

Done when each lane plan names its keepers, the carried assertions, the retired files, and the seams.

## 5. Cutover

Land the shared harness change first, through one owner, so every lane builds on it. Then one change per lane, each in its own worktree off the default branch, by a writer agent (prompt in [references/prompts.md](references/prompts.md), "Lane writer"):

- Apply every mark. Remove the seams the lane unlocks and move their proof to the real boundary.
- Every `F`, every `C`, and every seam removal that changes what a test reaches gets a **caught mutation**, as the discipline's "Changing and deleting existing tests" defines it. Record each one: ledger row, regression, production file and line, the failing assertion from the output, the byte-for-byte restore check, the passing rerun.
- A retained test that is red because the product is wrong keeps its assertion. The caller's policy decides between a fix in a separate change and a skip whose reason names the follow-up.
- Before each land, the `code-reviewer` agent, which wrote none of the change, reviews the diff against the default branch once; that is the lane's one review, and it judges each test because a lane's change is mostly tests. Check each finding against the source before you act on it, then fix, gate, and land.

A long campaign outlives many commits on the default branch. Merge the default branch into a lane branch; do not rebase it. When the default branch changed a test the lane deletes, keep the deletion and port the new contract into the keeper.

Done when every lane plan is applied and merged and the gate passes on the default branch.

## 6. Preservation review

This preservation review checks the campaign result against the ledger, not a change, so it is not a second review of a land. One reviewer per lane, who wrote none of the lane's diff, compares every ledger row at the pinned SHA with the final default branch (prompt in [references/prompts.md](references/prompts.md), "Preservation reviewer"). For each row it states the contract and finds the assertion that proves it now. Each suspected **gap** is proven in a scratch worktree: introduce the regression the old test caught and run the final keeper. A pass confirms the gap; a failure at an assertion after setup rejects it.

Reading is not enough here. In one campaign, a consolidation the orchestrator accepted by reading lost its proof, because a guard ran before the branch the reader followed.

Restore each confirmed gap in one change with a caught mutation, or reject it with source evidence, such as no code that writes the table.

Done when every row has a final proof or a settled gap, and every restored contract has a caught mutation.

## 7. Keep it from coming back

- A pattern a parser can decide, such as a test with no assertion or a test that reads source text, becomes a lint rule on the test directory, with a gate test that runs the real linter on bad samples.
- The repository gets a testing document, usually `docs/TESTING.md`: how to run the tests, the shared harness, the keeper for each area, every end-to-end script with the gate task that runs it or its manual prerequisites, and the pitfalls the campaign found. It holds repository facts; the rules stay in the discipline file. One line in `AGENTS.md` points to it for writing, changing, or deleting a test.
- A lesson that holds beyond this repository goes into the discipline file.

Done when the lint rules run in the gate, the testing document is merged, and its pointer is in `AGENTS.md`.

## Report

The report follows the discipline's "Report format", plus:

- the evidence for each step's completion criterion
- one row per lane: verdict and evidence
- test and production line counts at the baseline and at the end, counted separately
- each preservation gap and its mutation, or the reason it was rejected
- the follow-ups, including product bugs and areas with no keeper
- each change's URL, read back from the host

Every commit the report cites stays reachable. Give each unpushed scratch commit it cites a local tag, `proof/<task>-<n>`, because a branch cleanup can delete an unpushed branch, while a tag stays.
