# openclaw test-audit rules: adopt, adapt or reject

Each rule in openclaw's test-audit material at commit 70bfdc2b58e42f02af5bdc4d345875a9e6ad3928, and where Omer's rules hold it. The sources are `.agents/skills/test-audit/SKILL.md` (S), `.agents/skills/test-audit/references/audit.md` (A), `.agents/skills/test-audit/CAMPAIGN.md` (C) and `docs/help/testing/writing-tests.md` (W). "Discipline" is `agents/shared/testing-discipline.md`; "skill" is `agents/skills/test-audit/SKILL.md`. When the upstream files change, read their diff and update this table with the rules.

| openclaw rule | Decision | Where and why |
| --- | --- | --- |
| Name the protected behaviour and the credible regression (S) | Adopt | Discipline "The single test" |
| Explain why existing proof misses it; one owner per contract at the strongest boundary; extend tables and shared fixtures (S) | Adopt | Discipline "One owner per contract" |
| No export, flag, wrapper or injection hook without a production caller (S, A) | Adopt | Discipline "Cross the real boundary", seam paragraph |
| A regression fails before the fix for the intended reason; report missing baseline proof (S, W) | Adopt | Discipline "Bug fixes": fail at the assertion, not at setup |
| One owner regression covers a bug; never replay it at every layer (S) | Adopt | Discipline "Bug fixes" |
| A behaviour-preserving refactor does not break the test (S) | Adopt | Discipline "Prohibited test kinds", change-detector test |
| Reject self-comparisons and subject-generated expected values (S, A) | Adopt | Discipline tautological and assertion-free tests; lint rule where a parser can decide it |
| Reject copied inventories, manifests and export lists (S, A) | Adapt | Discipline tautological test, with the exception in "Contracts that stay" for a list checked against a second artifact maintained on its own, such as backup table coverage |
| Reject exact source, import and string greps (S, A) | Adapt | Discipline: a lint rule's job; reading a file stays allowed when the bytes are a consumer-facing contract |
| Reject private predicate and call-shape tests that duplicate boundary proof (S, A) | Adopt | Discipline change-detector and call-count items, "One owner per contract" |
| Reject duplicate contracts and provider-local replays of shared helpers (S, A) | Adopt | Discipline duplicate-assertion item |
| Reject mocks that implement the asserted behaviour (S, A) | Adopt | Discipline fake-against-fake item |
| Fixtures do not fabricate receipts, admission, callback order or a persistence path the code never writes (S, A) | Adopt | Discipline fabricated fixture |
| Reject capability flags asserted instead of delivery (A) | Adopt | Discipline capability-flag item |
| A negative control fails at its intended guard; names match what the test exercises (S, A) | Adopt | Discipline misaimed negative test; "The single test" on names |
| Retention bar: independent API, SDK, protocol, config, migration, storage, security, platform, default, prompt-byte, generated-language, package, release, architecture and ordering contracts (S, A) | Adapt | Discipline "Contracts that stay": the kinds that occur in Omer's repositories, plus the second-artifact test so the bar does not collide with the tautology ban |
| Static or slow is not a reason to delete (S, A) | Adopt | Discipline "Contracts that stay" |
| Source inspection survives identifier-only refactors and guards a user-facing contract (S, A) | Adopt | Discipline "Contracts that stay", third paragraph |
| A baseline failure may be a product bug; never delete a test for it (S, A) | Adopt | Discipline "Changing and deleting existing tests" |
| Read the full test, owner, callers, history and CI routing before an edit; record each candidate's evidence (A) | Adopt | Skill steps 3 and 4 |
| Missing evidence means no deletion (A) | Adopt | Discipline: a deletion records the proof that remains |
| Never chase deletion counts (S, A) | Adopt | Discipline "Changing and deleting existing tests" |
| Prefer net-negative production lines (A) | Adapt | Skill report: count test and production lines separately; the count is a report item, not a target |
| Proof policy: Vitest checkouts, `check-changed.mjs`, `--maxWorkers=1` (S, A, W) | Reject | openclaw tooling; the caller supplies the commands |
| Final autoreview (S, A) | Adapt | core.md: review verdicts come only from an agent that did not write the diff |
| Baseline with line counts at a pinned SHA; baseline failures in their own list (C1) | Adopt | Skill step 1 |
| Lanes along production owner boundaries, every file in one lane (C2) | Adopt | Skill step 2 |
| Read-only ledger per lane with R, F, C and D marks (C3) | Adopt | Skill step 3 |
| Layer plan: keeper per contract, real transport with a fake network over a mocked collaborator (C4, W) | Adapt | Skill step 4 keeps the keeper per contract; discipline "Cross the real boundary" allows no fake network, by Omer's rule that tests use no fakes |
| Cutover: shared harness through one owner, remove unlocked seams, register moved suites in CI routing (C5) | Adopt | Skill step 5 |
| Update shrink-only line-cap baselines (C5) | Reject | No such baselines in Omer's repositories |
| Durable test-ownership rules in the subsystem's `AGENTS.md` (C5) | Adapt | Skill step 7: a repository testing document with one `AGENTS.md` pointer, so `AGENTS.md` stays short |
| Preservation review, one reviewer per boundary group, a mutation per restored contract (C6) | Adopt, extended | Skill step 6; the discipline also asks for a mutation to confirm a deletion's remaining proof in another file or layer |
| Fix product defects inside the campaign with a control run (C7) | Reject | Omer's decision: a product bug becomes a follow-up; a red test is skipped with the follow-up as its reason |
| Merge main rather than rebase; keep a deletion main touched and port the new contract (C8) | Adopt | Skill step 5 |
| Review tooling sees a truncated file list on a large diff (C8) | Adapt | Skill step 5 reviews each lane change on its own |
| Cost budget of 5 s per file, 30 s needs a reason (W) | Reject | No measured basis here; a full suite run in the audited repository took about 10 s |
| Inject clocks; avoid real timers, sleeps and polling (W) | Adapt | Discipline seam paragraph: use the runner's mock timers or a clock production already passes; an injected clock only tests pass is a seam |
| Isolate each file's state; fix shared state instead of serial configs or worker pins (W) | Adopt | Discipline flaky-test item |
| Flake triage: reproduce the original order first, repair the producer (W) | Adopt, extended | Discipline flaky-test item, plus reproduction under the gate's load |
| Synthetic content; credentials stay out of captures (W) | Adopt | core.md "Secrets" |
| Live provider bugs: CI-safe regression at the smallest composition; live-only checks narrow and opt-in (W) | Adapt | Skill step 7: manual end-to-end scripts are listed in the repository testing document with their prerequisites |
| Many private controls point to fragmented ownership, not a need for test-only exports (W) | Adopt | Discipline seam paragraph, last sentence |
| Module mock export completeness, raw SQLite access, watcher cleanup, port claims, SecretRef classification (W) | Reject | openclaw harness specifics |
