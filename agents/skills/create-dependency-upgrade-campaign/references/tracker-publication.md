# Tracker Publication Reference

Read this file during Phase 6 and Phase 7.

## Contents

- [Publication order](#publication-order)
- [Parent specification](#parent-specification)
- [Subissue executor plan](#subissue-executor-plan)
- [Completion-comment contract](#completion-comment-contract)
- [Writing rules](#writing-rules)
- [Relationship and recovery rules](#relationship-and-recovery-rules)
- [Readback checklist](#readback-checklist)

## Publication order

1. Recheck the approved tracker identity, repository, authentication, labels, and relationship support.
2. Create approved campaign labels when required.
3. Publish the parent specification.
4. Read back the parent identifier.
5. Set the integration branch in the parent when the approved delivery model uses one.
6. Publish subissues in blocker-first order.
7. Add the approved parent and blocking relationships.
8. Replace all identifier placeholders.
9. Add the final issue table and dependency graph to the parent.
10. Read back and verify the complete campaign.

## Parent specification

Use these sections:

1. Problem Statement.
2. Solution.
3. Approved target matrix.
4. Campaign workflow.
5. User Stories.
6. Implementation Decisions.
7. Testing Decisions.
8. Out of Scope.
9. Further Notes.
10. Done.

The parent defines current truth.

Include the planned baseline commit and date.

Include the exact integration branch when the approved delivery model uses one.

Include the subissue table and dependency graph.

State which runtime issues remain open through post-merge proof.

State remote-action boundaries.

Do not add implementation file paths to the parent unless repository precedent requires them.

## Subissue executor plan

Use this order for each subissue:

1. Plan title.
2. Executor contract.
3. Metadata.
4. Why this matters.
5. Current state.
6. Approved target state.
7. Scope.
8. Decisions already made.
9. Drift check.
10. Implementation steps.
11. Machine-checkable done criteria.
12. Test plan.
13. STOP conditions.
14. Maintenance notes.
15. Official sources.

Metadata must include:

- Priority.
- Effort.
- Risk.
- Category.
- Dependencies and relationship representation.
- Planned baseline commit and date.
- Target executor.
- Issue and parent URLs.
- Integration branch.
- Remote-action authority.

Each plan must include:

- Exact current and target coordinates.
- Exact source-of-truth files and excerpts.
- Official migration and release sources.
- Compatibility decisions.
- Integrity coordinates.
- Exhaustive in-scope and out-of-scope boundaries.
- Shared-file ownership when another ticket edits the same file.
- Exact verification commands and success signals.
- Relevant allow and deny arms.
- Warning and deprecation policy.
- Rollback and recovery behavior.
- Environment-proof ownership.
- One logical commit subject and issue footer.
- Stop conditions for missing authority, evidence, or supported artifacts.

Write each plan for a fresh executor context.

Do not require the executor to rediscover a settled decision.

Allow controlled scope expansion only for migration work proven by official documents or failing checks.

Require the executor to record each controlled expansion before editing it.

## Completion-comment contract

Tell executors to separate local proof from live proof.

A local completion comment records:

- Commit identifier and subject.
- Exact changed behavior.
- Resolved versions and integrity proof.
- Tests, images, scans, warnings, and deny controls.
- Missing environment authority or credentials.
- Official documents used.

Keep the issue open when required live proof is missing.

A live completion comment records:

- Released commit or image identity.
- Environment and authorized workflow.
- Readiness and required smoke results.
- Access-control and failure results.
- Rollback state.
- Confirmation that secrets were not exposed.

Close a runtime issue only after all required proof exists.

## Writing rules

Use short active sentences.

Put one instruction in each sentence.

Use one term for one idea.

Keep code, commands, paths, identifiers, and required templates exact.

Use ASCII `->` in plain-text graphs.

Do not use em dashes or unicode arrows.

Do not claim certified ASD-STE100 compliance without an official validator.

## Relationship and recovery rules

Use the approved relationship representation.

Prefer native parent and blocked-by relationships when available.

Use text relationships only after the owner approves them during tracker capability binding.

Create only approved hard edges.

Keep motivating work unlinked when the owner chose manual sequencing.

Inspect existing tracker state before retrying any failed create request.

Reuse created issues after partial failure.

Never create replacement duplicates.

Mark a partial publication incomplete.

Record created identifiers, missing items, and missing relationships on the parent when update access remains.

Do not close or modify a referenced prior parent.

## Readback checklist

- Parent state is open.
- Parent has the approved labels.
- Subissue count is exact.
- Every subissue has the correct parent.
- Every relationship matches the approved representation and graph.
- Every issue has final URLs and no placeholders.
- Parent matrix matches approved decisions.
- Plan numbering and issue titles agree.
- Every plan has a target owner and proof owner.
- Excluded surfaces stay excluded.
- Repository status shows no new campaign source changes.
