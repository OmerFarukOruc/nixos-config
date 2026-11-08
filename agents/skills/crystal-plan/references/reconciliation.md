# Revise a plan

Read this after a plan-review REVISE or an executor's stop on one of the plan's Stop
conditions. An executor's stop arrives as the plan's stop report (Stop, Expected, Found,
Evidence); treat it as one finding.

1. Read every finding, the current plan, and the code at the plan's SHA. For each
   finding, name in one sentence the assumption that failed, or reject it with the
   evidence. A P3 finding you accept without an edit goes under `## Residual`.
2. Keep the plan's title and its document. Increment Revision. Keep every settled
   decision the findings leave intact; Omer's approach stays unless a finding shows it
   cannot work.
3. Settle each new decision from repository evidence and narrowly targeted research,
   then change every slice, Behavior line, Red, Green, touch set, and Final gate step it
   touches. Re-run every command whose output the edited text quotes; a count or a
   Green result recorded before the change proves nothing for a slice whose Change or
   Behavior changed, so observe it again or mark it NOT RUN.
4. Re-pin once: record the SHA you revised against in the header, and recheck every
   fact line whose file changed between the two SHAs.
5. Add a `## Revision history` line at the end of the plan: the revision, the date as
   `DD-MM-YYYY`, as Linear and handoff prose use, the decision that changed, and the
   finding it answers. Earlier revision lines stay.
6. Run the readiness checks on every slice the revision touched, plus the Drift, Pasted
   text, Secrets, and Length and format rows on the whole plan. Most later-round
   findings sit on text the previous revision inserted, so read the inserted text as the
   executor would before the handover.

When the approach itself is replaced, set Readiness to SUPERSEDED, point at the
replacement document in the first line, and start the replacement at Revision 1.

An executor's stop that names a drift between the plan and the code is a plan defect
until the code shows otherwise: fix the fact line, the decision, or the touch set, and
say which in the revision line.
