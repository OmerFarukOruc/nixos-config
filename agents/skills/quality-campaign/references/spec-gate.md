# Spec gate

An external adversarial reviewer grades the published campaign before any writer runs. Its question is "can these plans execute safely as written"; defect reality was settled in reconcile. A plan set that looks complete can still hide contradictory Done criteria, missing dependency edges, and acceptance checks that prove syntax instead of behavior. In the live trial the gate found blockers in 8 of 33 plans that three review models and a full verification pass had all missed.

## 1. Brief

Write a self-contained brief to a file. The reviewer sees nothing else. It carries: repo, parent issue number, subissue range, planning snapshot SHA, and the readiness contract below.

The campaign passes only when:

1. Every child issue has one unambiguous implementation contract.
2. Every Done criterion is simultaneously satisfiable.
3. Every prerequisite exists as native dependency metadata; body text is descriptive only.
4. No blocked issue carries the ready label.
5. Every claimed edge is necessary and every necessary edge exists, across write, read, drift, fixture, generated-artifact, public-contract, and persisted-format dependencies.
6. No child knowingly leaves another instance of its parent user story's defect untracked.
7. Every behavioral change has positive and negative proof.
8. No acceptance gate rests only on line numbers, grep counts, total test counts, or manual observation where semantic automation is feasible.
9. No issue prescribes a deliberately broken intermediate state.
10. No issue performs unsafe deletion, live deployment, secret exposure, or cloud mutation.
11. Persisted formats and public API contracts have explicit compatibility rules.
12. An implementation agent can execute each issue without unstated context.

Ask the reviewer for: a readiness grade per issue (BLOCKER, HIGH, MEDIUM), the finding and required correction per issue, and the minimum dependency-graph correction.

## 2. Run

Run the spec-gate binding. Expect one long turn; use the binding's recovery path on a timeout.

## 3. Triage

Verify every returned claim against the live issue bodies and code before acting. The gate gets the same skepticism as any other reviewer. Three outcomes, each recorded:

- **Confirmed**: fix the issue body. Use anchored, scripted edits that assert on every replacement, so nothing silently misses.
- **Refuted**: record the disproving evidence. Change nothing.
- **Not adopted**: real but outside the contract. Record the reason; offer it as a follow-up issue.

Then encode the confirmed dependency edges natively, remove the spurious ones, and prove the graph is acyclic. Update the parent so native metadata is the dispatch gate. Dispatch no writer while a confirmed blocker stands.
