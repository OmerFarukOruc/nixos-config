# Testing discipline

Every agent reads this before writing, editing, or deleting any test, and before proposing a test plan. It defines the Testing rules in your instructions. Where the `diagnosing-bugs`, `quality-campaign`, or `ub-mode` skill says something different about tests, this file wins. Apply it yourself; do not ask Omer whether a test is worth keeping. Each `##` section except "Example" is one rule that the `code-reviewer` agent checks by name.

## Choose the verification

Verification follows the risk of the change, and a finished task carries evidence that the behaviour works. Writing more tests does not complete a task.

- A complex feature, meaning one that crosses components, processes, or a network or storage boundary, is verified end to end. The run enters the system the way a user or caller does and asserts on the outcome that user or caller sees. When the report tells Omer to use a client he already runs, such as an app that starts through its own launcher or inside its own network namespace, the end-to-end run also reaches the system through that same launcher or namespace.
- A small, local change with low risk may need only the existing end-to-end tests that reach it, or one run of the real program. Say which check proves it.
- A new isolated test follows "Isolated tests need a request" below.

## Large Cloudflare tests need approval

Before a large test against live Cloudflare, present Omer with its cases, estimated rows written, estimated cost, and cleanup plan.
Wait for his explicit yes.
Include staging, index maintenance, replacement, cleanup, and failure or retry paths in the write estimate; mark assumptions and unknowns.
This includes bulk imports, restore rehearsals, large fixtures, and load tests, even on disposable resources or within an included allowance.
If the writes cannot be bounded, keep the run local until the estimate is ready for approval.
Approval to implement a change or run its tests does not authorize these remote runs.
Approval covers only the described cases and write budget; seek a new yes before expanding either.
Use the local vendor runtime for development and regression checks while approval is pending.

## The end-to-end scenario

The scenario is medium or hard. It exercises what the change can break, so it includes at least two of these:

- State that already exists before the run, such as seeded data, a prior session, or a config that is not the default.
- A failure or edge path the feature must handle, such as a timeout, a rejected input, a retry, a partial write, or a permission denial.
- More than one step or actor, such as create then update then read back, or two clients on the same resource.
- A realistic size or shape of input, not a single minimal record.

A scenario that only proves the feature starts and returns success on the simplest input is the happy-path smoke test. It can stay as an extra check, but it never counts as the end-to-end proof.

## The artifact

Every end-to-end verification ends with an artifact that another agent can verify and repeat:

- The exact command that reproduces the run, with its environment and seed data named.
- The captured result: the test report, output log, response bodies, database state, or screenshot the assertion read.
- The pass condition, stated so a rerun can be compared against it.

Keep the artifact where the repository keeps test output, or name its path in the final report. An artifact with no rerun command is not repeatable. A claim with no captured result is not verifiable.

## Running end-to-end tests

During development, run only the end-to-end tests that the change touches. Run the full end-to-end suite once, after the review fixes and before landing, unless it needs the landed system, and report its result; an edit after that run to a file it exercises means one more run.

A proof that takes more than a few minutes runs last: after the gate passes, an independent review reports, and its fixes are in. A review fix to any file the proof exercises forces the proof to run again, so running it before the review spends one run per review round. A quick end-to-end check of the touched path may still run during development.

## Isolated tests need a request

Verify a change by running the real program or system the way its user or caller does, and keep that run as the evidence under "The artifact". Write a new unit test or other isolated test only when Omer asks for one, or when the repository's own instructions (`AGENTS.md`, `CLAUDE.md`, or a testing policy such as `docs/TESTING.md`) require one for that change. A repository that already has tests does not by that fact require new ones, because tests added to match a folder restate the code as written.

A requested or required isolated test is written before the code it covers:

1. List the ways the unit can fail: bad input, boundary values, dependency failures, ordering, concurrency, and invalid states. Write the list down.
2. Write a test for each failure on the list that the unit must handle and no end-to-end test can reach on purpose. Run each one and see it fail.
3. Write the code until those tests pass.

Include the failure list in the final report. When the implementation already exists, verify it with a real run instead.

Repairing or consolidating an existing test is not a new isolated test, so this rule does not apply to it. Its proof is a caught mutation, defined under "Changing and deleting existing tests".

## Bug fixes

Prove a bug fix by reproducing the bug through the real program, then running the same reproduction on the fix. Report both runs. Then find the tests that cover the broken behaviour.

- When an existing test should have caught the bug, fix that test's assertion or scenario. Do not add a second one.
- When no test exercises the behaviour that broke and the repository has an end-to-end suite that reaches it, add the reproduction to that suite at the owner of the contract (see "One owner per contract"). Run it against the unfixed code and see it fail at the assertion for this bug, not at setup. Then apply the fix. A new isolated test for the gap follows "Isolated tests need a request".
- Otherwise add no test. The two reproduction runs are the evidence.

A bug proven once at its owner is proven. Do not replay the same regression at every layer the bug crossed.

## The single test

A test earns its place only by passing the single test: name the requirement it proves, in one sentence, and name the regression its failure would catch, in one sentence, and confirm nothing else already catches that regression. A test that cannot fill both sentences does not get written, or gets deleted if it already exists.

Prove a new test discriminates. Run it against the pre-change code, see it fail, then restore the change. A test that passes both ways pins nothing.

Judge a test by its assertions, not its name. The name says what the test exercises, and a test whose name promises behaviour its inputs or assertions never reach is renamed or repaired.

## One owner per contract

Each contract has one owner test, at the strongest real boundary that can reach it: the real transport, store, or process. A second test of the same contract at another layer earns its place only when that layer adds its own risk, such as a different transport, lifecycle, or serialization. Otherwise its assertions move into the owner and the copy goes.

Extend the owner's table of cases or its shared fixture instead of adding a parallel test. When several tests repeat the same setup, consolidate the setup into one helper.

## Prohibited test kinds

Each of these fails the single test for a specific reason. Recognize the pattern and skip it, or delete it on sight:

- **Tautological test.** It passes by construction, so it can never disagree with the code. This includes a test that reimplements the function under test to compute its expected value, an assertion that a constant, enum, field list, or table equals what the source already says, a check that a substring exists in a constant string, and a snapshot derived the same way the code derives it. Expected values come from an independent source: the spec, a worked example, a known-good literal, or a second artifact maintained on its own (see "Contracts that stay").
- **Change-detector test.** It fails on any change to the implementation, even when behaviour is unchanged, and passes when behaviour breaks in a way it does not mirror. This includes asserting an exact SQL string, internal call order, private method output, log wording, or a snapshot of internal structure. A refactor that keeps behaviour must leave the test green.
- **Assertion-free test.** It calls code and asserts nothing, so only a crash can fail it. An assertion whose two sides are the same expression belongs here too.
- **Fake collaborator.** A fake, stub, mock, or stand-in that the test or the project builds to imitate a collaborator: a local server that answers like a third-party API, a fake `ssh` or browser early in PATH, an in-memory store in place of the real one, or a mock object. It proves only that the code matches the fake. "Cross the real boundary" says what replaces it.
- **Fabricated fixture.** A fixture hands the code what its production owner should produce, such as a receipt, an acknowledgement, an admission decision, a callback order, or a row in a store path the code never writes. The test then proves the code accepts a world that cannot occur.
- A capability flag asserted in place of the delivery or acknowledgement the flag promises.
- A call-count or call-order assertion, unless the interaction itself is the contract (a webhook that must fire exactly once, a lock that must release before retry). Most call counts are implementation detail, not behavior.
- **Misaimed negative test.** A rejection test that passes because an unrelated guard rejected the input first, or that asserts a rejection the production code never reaches. A negative test fails at the guard it targets. Prove that by removing that guard and seeing the test fail.
- A test that reads source text or file structure to enforce a coding rule. That is a linter's job. Add a lint rule instead, unless the repo has no lint hook for that rule.
- A test written to raise a coverage or mutation number. The number is not the requirement.
- A test that duplicates an assertion another test already makes. It proves nothing new and costs maintenance forever. A test is a duplicate only when every regression its assertions catch also fails another test. One regression caught elsewhere is not enough, because the test can still be the only one that fails for another regression.

## Contracts that stay

A test of an independent contract stays even when it is static, slow, or reads a file. Independent contracts are API, protocol, config, migration, storage, security, and default-value contracts, generated artifacts a consumer reads, and observable ordering. Such a test is not tautological when it checks one artifact against a second artifact that is maintained on its own, because either side can drift alone.

The worked example is the backup table coverage test. It migrates a database and checks every table the migrations create against `BACKUP_TABLES`. The migrations and the list are written separately, so a new table without a backup entry fails the test. A test that asserts `BACKUP_TABLES` equals a copy of itself pasted into the test is tautological, because the copy can only drift by hand.

Reading a file stays allowed when the bytes are the contract a user or consumer sees, such as a config key, a prompt, a route path, a JSON catalog, or a generated bundle, and the check survives a rename of internal identifiers. Reading source code to check its shape is a lint rule's job.

Tests that run production code against an independently specified outcome also stay, including controlled failure orderings, concurrency races, malformed input handling, privacy or redaction completeness, and config rejection at startup. They bring the case about through real boundaries, such as a damaged file in the real state folder, a lock held by a real second process, or a made-up token the real service refuses. A case that only a fake collaborator can produce stays unproven, as "Cross the real boundary" says.

## Cross the real boundary

Tests use no fakes. A test crosses every boundary its claim depends on for real: a real database in a container, the real HTTP service, the real queue, a real SSH server, the real file lock. A local runtime or emulator that a vendor ships for its own service counts as real, such as `wrangler dev` for Workers and Workers KV, because it runs the vendor's code rather than an imitation the test built.

Reach a third-party service without an account by sending it input whose real answer is the behaviour under test: a made-up token that the sign-in service refuses, or a proxy setting that points at a closed local port for a network failure. An invented answer passes while production fails: a `.github/workflows/release.yml` route that returns 404, a job named `build-push` that GitHub lists as `build-push / build-push`, a job log read as a zip that GitHub serves as text.

When no real run can reach a contract, such as one that needs a signed-in account, the contract stays unproven. Delete the test that faked it, and record the contract as unverified where the repository describes its tests, such as the README, and in the PR body. A fake is never the fallback.

The clock is the one thing a test may set: with the test runner's mock timers, a clock that production already passes in, or a patch that replaces only the current time while the real time-zone data and parsing run.

Production code carries no test-only seam: an export, flag, wrapper, getter, reset hook, global, or injection parameter that only tests use. Move the proof to the real boundary and remove the seam with the test that needed it. An injection parameter stays when production passes a real implementation through it. Many private controls in one module point to an owner split across too many places, not to a need for more exports.

## Before adding a test file

Check the repo's testing policy document if one exists (for example `docs/TESTING.md`). Name the existing test that comes closest to the one you're about to write and the owner of its contract. Add to that test or its file rather than starting a parallel one.

## Changing and deleting existing tests

When you touch a test file, apply the single test to the tests in it. Each test ends in one of four states: retained, repaired, consolidated into a named owner, or deleted. A test being green is not a reason to keep it, and the number of deleted tests is never a goal.

- **A deletion records the proof that remains**: the owner test that still catches the regression, or the reason no contract exists. Without that record, keep the test. When the remaining proof sits in another file or at another layer, confirm it with a mutation for each regression the deleted test caught, and run the full suite on each. Reading the owner is not enough, because a guard that runs before the branch the reader followed can answer first.
- **A failing test may be a product bug.** Reproduce the failure. If the code is wrong, the test stays; fix the code in this task or record a follow-up, never delete the test to get green.
- **A test skipped for a known product bug proves itself against a simulated fix.** Apply the smallest correct fix in a scratch copy, run the test unskipped, and see it pass; without the fix it fails at the assertion for that bug. A test that a correct fix cannot turn green, such as one whose setup reuses a one-time code the fix will refuse, gets repaired before it is skipped. Run the file's other tests against the same fix too: a test whose refusal would now come from the new guard instead of its own no longer proves its contract, so aim it before the fix lands.
- **A repair or consolidation proves itself with a caught mutation.** Name the regression and the assertion that must catch it. Introduce that regression in the production owner, see that assertion fail after setup succeeded, restore the source byte for byte, and see the test pass. An import, compile, fixture, or unrelated-guard failure does not count.
- **A flaky test gets reproduced in its original order first, then under the gate's load.** Order-only failures usually mean shared state that an earlier test left behind. Failures only under load usually mean the test waits on a proxy, such as a status row written before the work it names starts; wait for the event the assertion depends on. To reproduce load, run the file many times at once. Fix the shared state, the wait, or the producer. A retry or a serial pin hides the cause.

## Report format

When a task produces or changes tests, or claims end-to-end verification, the final message includes:

- Each test, one line per test: the requirement it proves, then the regression it would catch. A test that cannot fill that line is deleted before the report, not reported as-is.
- Each deleted test, with the proof that remains or the reason no contract exists.
- Each repaired or consolidated test, with its caught mutation.
- For end-to-end verification, the scenario in one sentence, why it is medium or hard, the rerun command, and the artifact path.
- For isolated tests, the failure list written before the code.
- For a bug fix without a new test, the existing test that covers it or the reason no test was added.

## Enforcement

Lint rules reject the patterns a parser can decide, such as a test with no assertion, an assertion that compares an expression with itself, or a test that asserts on source text. Add such a rule to the repository's lint config when it repeats. The change's one review judges everything else. When a change adds, edits, or deletes tests, fixes a bug, or claims end-to-end verification, that review applies this file: the `code-reviewer` agent (`code_reviewer` in Codex), or another reviewer with this file named in its prompt. It runs once on the diff in its final landing shape, after the gate and before the long end-to-end proof; check each of its findings against the source before you act on it. Do not add a test-admission scanner, a coverage gate, a mutation gate, or a Claude Code hook to enforce this.

## Example

Bad, a fake-echo test:

```python
def test_retry_calls_backoff_three_times():
    backoff = FakeBackoff()
    client = Client(backoff=backoff)
    client.call_with_retry(lambda: (_ for _ in ()).throw(TimeoutError()))
    assert backoff.call_count == 3
```

This proves the fake backoff object was called three times. It says nothing about whether retries survive a real timeout.

Good, a real-boundary replacement:

```python
def test_a_query_survives_a_database_restart(postgres_container):
    client = Client(postgres_container.url)
    postgres_container.stop()
    threading.Timer(2, postgres_container.start).start()
    assert client.call_with_retry(lambda: client.fetch_one("select 1")) == (1,)
```

This runs the production retry loop against a real database that refuses connections for two seconds, so a broken retry loop fails the test. Requirement: a query survives a database restart. Regression it catches: a retry loop that gives up early or swallows the eventual success.

If no real database could run in the test environment, the correct move is deletion, reported as: "removed the call-count test, no real-boundary replacement exists yet, retry behavior is unverified until one does."
