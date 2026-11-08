# Create route

Outcome: a published GitHub issue campaign that a writer can execute with zero context from this session, cleared by the spec gate. This session changes no code. Its only writes are GitHub issues, labels, and dependency metadata.

## 1. Frame

- Confirm the working tree is clean. Record the current commit SHA as the planning snapshot; every subissue's drift check references it.
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

- Parent issue via `/to-spec`. One subissue per cluster via `/to-tickets`, each an implementation plan following the plan template `~/.claude/skills/improve/references/plan-template.md`. Write every body with `/writing-for-agents`.
- Every subissue carries: exact paths, current-vs-desired code re-quoted from the live files, a verify command per step, Done criteria, STOP conditions, and a drift check against the planning snapshot.
- Native sub-issue links, a bundle label, severity and type labels.
- Compute dependencies from extracted write and read sets, never from intuition. An edge exists when an earlier slice can invalidate a later slice's assumptions: same-file writes, read prerequisites, drift-check files, test fixtures, generated artifacts, public contracts, persisted formats.
- Encode every edge as a native GitHub blocked-by relation. Body "Depends on" text is descriptive only. A blocked issue never carries the ready label.
- The parent issue encodes the full execution protocol, including the endgame, so the orchestrate session needs nothing from this one.

## 5. Spec gate

Run [spec-gate.md](spec-gate.md). The campaign is ready for dispatch only after every gate verdict is triaged and every confirmed correction is applied.
