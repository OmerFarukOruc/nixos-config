---
name: create-dependency-upgrade-campaign
description: Build and publish a verified dependency upgrade campaign with a parent issue and linked subissues.
disable-model-invocation: true
---

# Create Dependency Upgrade Campaign

## Contract

Use the relevant conversation, repository state, tracker history, and owner decisions as campaign inputs.

Research the current system and exact upgrade targets before designing tracker work.

Publish only after the owner approves the exact tracker write set.

Create an evidence-backed parent specification and executable linked subissues.

Verify the published campaign through tracker readback.

Keep repository source read-only and preserve the pre-existing worktree state.

Do not implement upgrades, create branches, commit, push, open pull requests, release, or deploy.

## Phase 1: Bind the brief

Read the complete relevant conversation before asking questions.

Extract these inputs:

- Repository and tracker.
- Tracker capabilities and relationship representation.
- Exact campaign labels or the repository rule that defines them.
- Outcome and motivating work.
- Reference campaigns and issues.
- Included and excluded surfaces.
- Version policy.
- Breaking-change policy.
- Required external behavior.
- Verification and environment gates.
- Delivery model and authority limits.
- Confirmed decisions and unresolved owner choices.

Look up repository and tracker facts.

Probe tracker authentication and support for issue creation, updates, labels, parent links, blockers, and readback.

Use a configured tracker connector when it supports every required operation.

Use the documented tracker CLI only for missing operations.

Stop before campaign design when no safe tracker adapter can prove the required operations.

When native relationships are unavailable, get owner approval for an explicit text representation before ticket design.

Ask only for unresolved owner decisions.

**Complete when:** every relevant decision, tracker capability, relationship representation, and label value appears once in the brief ledger.

## Phase 2: Audit the current system

Read repository instructions, domain terms, decision records, status, baseline commit, and dirty-worktree state.

Inspect the full bodies and comments of referenced campaigns.

Inspect their subissues and completion comments when they define the expected evidence model.

Read [version-audit.md](references/version-audit.md) before scanning version surfaces.

Build an exhaustive direct-version ledger.

Record current components that need no change.

Record unused dependencies and abandoned direct dependencies.

Keep platform-managed transitives under their platform unless evidence requires an override.

Preserve unrelated worktree changes.

**Complete when:** every direct version surface inside approved scope has an owner and current coordinate, and the ledger records baseline SHA and dirty paths.

## Phase 3: Resolve exact targets

Use primary official sources.

For production runtimes, present newest supported LTS and newest stable when they differ.

For libraries and build tools, present the newest stable release.

Exclude preview releases unless the approved brief includes them.

Verify compatibility ranges, migration guides, artifact availability, image tags, action commits, checksums, and digests.

Investigate conflicts before asking the owner.

Ask one decision question at a time.

Give a recommended answer with each question.

Never ask the owner to discover a repository or release fact.

Resolve unavailable targets through an approved distribution or acquisition decision.

**Complete when:** the owner approves the complete exact target matrix.

## Phase 4: Fix the verification seam

Select the highest stable seam that proves the campaign.

Prefer the released image set in staging for runtime campaigns.

Define local, CI, image, staging, production, rollback, allow, and deny proof.

Map production proof only to live-risk surfaces.

Account for workflows that can run only after merge.

Keep affected runtime issues open until their required environment proof exists.

**Complete when:** the owner approves the seam and closure rules.

## Phase 5: Design tracer tickets

Create one fresh-context subissue for each logical slice.

Give each change subissue one logical commit.

Use a shared integration branch when the campaign follows that delivery model.

Add only blocking edges that make a later slice impossible to start safely.

Keep independent slices independent.

Assign every target-matrix row and every environment gate to an owner.

Define shared-file seams between sequential tickets.

Give the parent responsibility for the final integration and closure gates.

Run external critics only after the owner authorizes a named provider and its tool policy is proven read-only.

Otherwise, perform a local evidence review and report that external critics were skipped.

Review for missing ownership, false blockers, unsafe parallel work, unverifiable gates, rollback gaps, and scope leakage.

Send no secrets or irrelevant private context to critics.

Reconcile critic findings against repository evidence and confirmed decisions.

Present the revised breakdown.

Ask these approval questions one at a time:

1. Is the granularity correct?
2. Are the blocking edges correct?
3. Should any ticket merge or split?

**Complete when:** the owner approves boundaries, edges, and merge decisions.

## Phase 6: Publish the campaign

Read [tracker-publication.md](references/tracker-publication.md) before any tracker write.

Recheck tracker authentication and every required write operation.

Compare the repository baseline and dirty paths with the Phase 2 snapshot.

Re-audit affected surfaces and renew approvals when drift changes the proposed campaign.

Show the exact write set before publication.

Include the target tracker and repository, exact labels or label rule, complete issue bodies, relationships, and integration branch when used.

Ask the owner to approve this exact write set and authorize publication.

Create nothing until the owner approves.

Create a new parent issue.

Do not reopen an old campaign.

Create or reuse the approved labels.

Publish subissues in dependency order.

Create the approved native or text relationships.

Update the parent with final issue identifiers and the rendered dependency graph.

Keep referenced future work independent unless the owner approved links.

**Complete when:** the parent body and every subissue contain final tracker identifiers without placeholders.

## Phase 7: Verify the campaign

Fetch the published parent and every subissue from the tracker.

Compare the baseline commit and worktree state with the Phase 2 snapshot.

Report concurrent drift and do not claim a stable audit snapshot when either changed during the run.

Verify these invariants:

- The parent has the expected number of subissues.
- Every subissue points to the parent.
- Relationships match the approved representation and graph.
- Every issue has the approved labels.
- Every approved target has one issue owner.
- Every runtime change has environment-proof ownership.
- Every issue contains exact scope, commands, checks, rollback, stop conditions, and official sources.
- No placeholder remains.
- No forbidden relation was added to motivating work.
- The repository worktree has no new campaign source change.

Correct tracker-only defects inside the approved campaign scope.

Do not change the approved target or ticket graph silently.

When an invariant cannot pass, leave the campaign incomplete.

Report the failing invariant, affected identifiers, and proposed correction before more writes.

When repository drift occurs after publication, list affected surfaces and keep the baseline provisional.

Require owner approval to accept the new baseline or re-audit affected tickets.

Report the parent, ordered subissues, approved graph, late discoveries, and preserved local state.

**Complete when:** each invariant passes through tracker readback and worktree inspection.

## Recovery rules

Inspect tracker state before retrying a failed write.

Reuse a successfully created parent or subissue.

Never create a duplicate to recover from an uncertain response.

For a partial publication, record created identifiers, missing items, and missing relationships on the parent when update access remains.

Keep the campaign incomplete until Phase 7 passes.

When an artifact target disappears, verify official alternatives before asking for a new decision.

When required authority or credentials are unavailable, preserve completed local planning and report the exact missing gate.
