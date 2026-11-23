# Create route

Outcome: a published GitHub issue campaign that a writer can execute with zero context from this session, cleared by the spec gate. This session changes no code. Its only writes are GitHub issues, labels, and dependency metadata.

## 1. Frame

- Confirm the working tree is clean. Record the full commit SHA and the branch as the planning snapshot; every subissue's `Repository:` line and drift check reference it.
- State the frame in one sentence before reviewing: the implementer is a cheap writer that saw none of this session, so every artifact must be self-contained.

## 2. Council review

Write one review brief and give it to every reviewer, internal and external:

- Full-repo pass.
- For every third-party language, framework, and tool found in the repo, fetch the official conventions or best-practice docs. Review our usage against them.
- Findings in a strict format: file, defect, severity, evidence, verify command.

Dispatch the council (bindings) in the background first, then run the internal deep review (bindings) while they work. Collect the council reports when the harness notifies.

## 3. Reconcile

- Give every external finding its own adversarial verifier, prompted to refute it against the live code. Drop what does not reproduce.
- Deduplicate the survivors by file and defect across all reports.
- Check the tracker's earlier campaigns. Drop findings already fixed or owned by another campaign.
- Cluster the survivors into slices. A slice is one coherent implementation unit.

## 4. Publish

- Parent issue via `/to-spec`. One subissue per cluster via `/to-tickets`. Each subissue body is a crystal-plan plan with one slice, which replaces the to-tickets ticket template: copy `~/.claude/skills/crystal-plan/assets/plan-template.md` and pass `~/.claude/skills/crystal-plan/references/readiness-checklist.md`. Write every body with `/writing-for-agents`.
- The orchestrate route and the spec gate read these fields, and each sits in one template line or section:
  - Commit subject: the slice's `Commit:` line.
  - Files a writer may change, for the same-file collision check: the slice's `Touch set:` line.
  - Landing: the header's `Landing:` line says "commit on the slice branch; the orchestrator merges it into the integration branch", because a writer never pushes or opens a PR.
  - Prerequisites: the slice's `Blocked by:` line lists the blocking subissue numbers, the same edges as the native blocked-by relations below.
  - Drift check: the `Repository:` line pins the planning snapshot recorded in Frame, and Change step 1 runs `git diff --stat <snapshot> --` over the Current state and touch-set paths. The `Touch set:` lines of the subissues in `Blocked by:` count as the touch sets of earlier slices, both in Change step 1 and in the first Stop condition, because a blocked slice branches off an integration head that already holds them.
  - Proof: the writer captures the `Red:` output before the change. After it, the writer reports and the orchestrator reruns `Green:` and the Final gate rungs marked `worktree`, and checks the output against every `Behavior:` line and the `Done when:` condition. `Done when:` is a condition, not a command, and each `Behavior:` line is a positive or negative proof that can fail.
  - Final gate: each rung names its stage, `worktree`, `integration`, `PR` or `post-merge`. The orchestrator runs the `integration` rungs after the merge and the `PR` and `post-merge` rungs in its endgame.
  - Stop conditions: the plan's Stop conditions section.
- Native sub-issue links, a bundle label, severity and type labels.
- Compute dependencies from extracted write and read sets, never from intuition. An edge exists when an earlier slice can invalidate a later slice's assumptions: same-file writes, read prerequisites, drift-check files, test fixtures, generated artifacts, public contracts, persisted formats.
- Encode every edge as a native GitHub blocked-by relation. Body "Depends on" text is descriptive only. A blocked issue never carries the ready label.
- The parent issue encodes the full execution protocol, including the endgame, so the orchestrate session needs nothing from this one.

## 5. Spec gate

Run [spec-gate.md](spec-gate.md). The spec gate stands in for crystal-plan's plan-review pass, so after its triage set `Readiness: READY` in each cleared subissue body. The campaign is ready for dispatch only after every gate verdict is triaged, every confirmed correction is applied, and every subissue reads `Readiness: READY`.
