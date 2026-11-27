# Testing discipline

Every agent reads this before writing, editing, or deleting any test, and before proposing a test plan. It defines the Testing rules in your instructions. Where the `diagnosing-bugs`, `quality-campaign`, or `ub-mode` skill says something different about tests, this file wins. A repository's own testing policy (`docs/TESTING.md`, a testing section in its `AGENTS.md` or `CLAUDE.md`, or a CONTRIBUTING file) wins where it differs from this file, so read it first. It can make the approval in "Large tests on a live service that bills by use need approval" stricter and cannot lift it, because an approval gate from any layer holds until Omer lifts it (`core.md`). A rule that holds for one project lives in that policy, and this file holds the rules for every project. Apply it yourself; do not ask Omer whether a test is worth keeping. Each `##` section except "Example" is one rule that the `code-reviewer` agent checks by name.

## Choose the verification

Verification follows the risk of the change, and a finished task carries evidence that the behaviour works. Writing more tests does not complete a task.

- A complex feature, meaning one that crosses components, processes, or a network or storage boundary, is verified end to end. The run enters the system the way a user or caller does and asserts on the outcome that user or caller sees. When the report tells Omer to use a client he already runs, such as an app that starts through its own launcher or inside its own network namespace, the end-to-end run also reaches the system through that same launcher or namespace.
- A small, local change with low risk may need only the existing end-to-end tests that reach it, or one run of the real program. Say which check proves it.
- A new isolated test follows "Isolated tests need a request" below.

## Large tests on a live service that bills by use need approval

Before a large test against a live service that bills by use, such as a cloud database, a queue, or a paid API, present Omer with its cases, estimated billed usage, estimated cost, and cleanup plan.
Wait for his explicit yes.
Include setup, staging, index maintenance, replacement, cleanup, and failure or retry paths in the usage estimate; mark assumptions and unknowns.
A bulk import, a restore rehearsal, a large fixture, and a load test are large, even on disposable resources or within an included allowance, and so is a test above the threshold the project's testing policy names.
If the usage cannot be bounded, keep the run local until the estimate is ready for approval.
Approval to implement a change or run its tests does not authorize these remote runs.
Approval covers only the described cases and budget; seek a new yes before expanding either.
Use the local vendor runtime for development and regression checks while approval is pending.
The project's own testing policy names the unit to estimate, such as rows written on Cloudflare D1, the flag that caps it, and any threshold.

## The end-to-end scenario

The scenario is medium or hard. It exercises what the change can break, so it includes at least two of these:

- State that already exists before the run, such as seeded data, a prior session, or a config that is not the default.
- A failure or edge path the feature must handle, such as a timeout, a rejected input, a retry, a partial write, or a permission denial.
- More than one step or actor, such as create then update then read back, or two clients on the same resource.
- A realistic size or shape of input, not a single minimal record.

A scenario that only proves the feature starts and returns success on the simplest input is the happy-path smoke test. It can stay as an extra check, but it never counts as the end-to-end proof.

## The artifact

Every end-to-end verification ends with an artifact that another agent can verify and repeat:

- The exact command that reproduces the run, with its environment and seed data named. Run a test runner in its single-run mode, so the command ends by itself, and with every result cache in the run off, such as `go test -count=1`, or `turbo run test --force` together with the inner test command's own flag, because a cached pass replays an earlier run's log, its test count included, and executes no test. The captured log shows no cache-hit marker, such as Go's `(cached)` or Turborepo's `cache hit, replaying logs`.
- The captured result: the test report, output log, response bodies, database state, or screenshot the assertion read.
- The pass condition, stated so a rerun can be compared against it. For a test runner it names the tests or the number of tests that ran, because a filter that selects zero tests can still exit 0. For a direct run of the program it names the operation, its input, and the output or state that passes.

Keep the artifact where the repository keeps test output, or name its path in the final report. An artifact with no rerun command is not repeatable. A claim with no captured result is not verifiable.

## Running end-to-end tests

During development, run only the end-to-end tests that the change touches. When you cannot tell which tests a change reaches, as with a shared helper, a fixture, config, a generated file, or a dynamic lookup, run every test file that loads it, or the full end-to-end suite when you cannot list those files, because a selection that finds no test is not evidence that nothing breaks. Run the full end-to-end suite once, after the review fixes and before landing, unless it needs the landed system, and report its result; an edit after that run to a file it exercises means one more run.

A proof that takes more than a few minutes runs last: after the gate passes, an independent review reports, and its fixes are in. A review fix to any file the proof exercises forces the proof to run again, so running it before the review spends one run per review round. A quick end-to-end check of the touched path may still run during development. An equivalence check that replaces a review runs on the final head, because a later edit to a file it covers voids it.

## Probes that start a process

A probe that starts an app, server, or TUI ends by stopping every process it left. Each run makes its own scratch folder (`mktemp -d`), so a second copy that runs at once keeps its processes. List the processes whose environment or working directory points into that folder (`/proc/<pid>/environ`, `/proc/<pid>/cwd`) and stop each by its PID, because an app can leave its own server running under the user's systemd, outside `timeout`, on a fixed port the user's own copy needs. A probe or check script that starts processes also stops them on SIGTERM and SIGINT and on an error in its own scenario, and proves it by sending SIGTERM in the middle of a run and listing what is left, because a cleanup that runs only at the normal end leaves processes behind after a cancelled or crashed run, and a library's own signal handler can end the process before the script's handler runs.

## Isolated tests need a request

Verify a change by running the real program or system the way its user or caller does, and keep that run as the evidence under "The artifact". An isolated test runs one unit of code without the real boundaries its callers cross, as a unit test does. Write a new isolated test only when Omer asks for one, or when the repository's own instructions (`AGENTS.md`, `CLAUDE.md`, or a testing policy such as `docs/TESTING.md`) require one for that change. A repository that already has tests does not by that fact require new ones, because tests added to match a folder restate the code as written.

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

Prove a new test discriminates. Run a test of new behaviour or of a bug fix against the pre-change code and see it fail at its own assertion after setup succeeded, then restore the change. An import, compile, or fixture failure does not count, unless that failure is the defect. For a unit that does not exist yet, the run that counts is the first one that reaches the assertion, with the entry point in place and the behaviour not yet written. A test that replaces, repairs, or consolidates an existing test passes on the pre-change code, so its proof is the caught mutation of "Changing and deleting existing tests". A test that passes both ways pins nothing.

When a fallback or another mechanism can produce the same result, the test also shows that the path under test ran, so it fails when the feature is off. The proof is a signal a user or caller can see, such as a response header, a printed query plan, a public metric, or the real backend receiving no request, or it is a control run that turns the feature off through its real config and gets a different result. An internal counter, a spy, log wording, or a test-only seam is not that signal, because a user or caller cannot see it. When the product offers neither a signal nor a switch, rename the test to what it proves and record the path as unproven, as "Cross the real boundary" says for a contract no real run can reach.

Give each input that the code treats differently a value of its own, and test each boundary at the boundary and one step on each side of it, because a fixture that sets two fields to the same value passes when the code swaps them. When inputs cannot all take distinct values, such as three flags, use one scenario for each input.

Judge a test by its assertions, not its name. The name says what the test exercises, and a test whose name promises behaviour its inputs or assertions never reach is renamed or repaired.

## One owner per contract

Each contract has one owner test, at the strongest real boundary that can reach it: the real transport, store, or process. A second test of the same contract at another layer earns its place only when that layer adds its own risk, such as a different transport, lifecycle, or serialization. Otherwise its assertions move into the owner and the copy goes.

Before adding a test, name the existing test that comes closest to it and the owner of its contract. Extend the owner's table of cases or its shared fixture, or add the test to the owner's file, instead of starting a parallel test or a parallel test file. When no test owns the contract yet, the new test becomes its owner, and it goes in the closest test's file when that file runs at the owner's boundary. When several tests repeat the same setup, consolidate the setup into one helper. A helper holds only the shared setup: the input and the expected value that make a case what it is stay in the test body or in its table row, so a reader sees both without opening a helper.

## Prohibited test kinds

Each of these fails the single test for a specific reason. Recognize the pattern and skip it, or delete it on sight:

- **Tautological test.** It passes by construction, so it can never disagree with the code. This includes a test that reimplements the function under test to compute its expected value, an assertion that a constant, enum, field list, or table equals what the source already says, a check that a substring exists in a constant string, and a snapshot derived the same way the code derives it. Expected values come from an independent source: the spec, a worked example, a known-good literal, or a second artifact maintained on its own (see "Contracts that stay").
- **Platform test.** Its assertion depends only on the framework, browser, runtime, library, or type checker, so no change to our code can fail it: a static button that renders, a click event that fires, a row read back straight after the ORM saved it, or a fact the type checker already guarantees. A test that crosses a real database or browser to check an outcome our code decides is not a platform test.
- **Change-detector test.** It fails on any change to the implementation, even when behaviour is unchanged, and passes when behaviour breaks in a way it does not mirror. This includes asserting an exact SQL string, internal call order, private method output, log wording, or a snapshot of internal structure. A refactor that keeps behaviour must leave the test green.
- **Assertion-free test.** It calls code and asserts nothing, so only a crash can fail it. An assertion whose two sides are the same expression belongs here too.
- **Weak assertion.** It checks truthiness, existence, a length or count, or a status code alone, where the contract promises a value, so a wrong result passes. Assert the value the contract promises: the returned rows, the field values, the error code. Wording, field order, and fields the contract leaves open stay unasserted, because asserting them makes a change-detector test. A count or a status alone is enough when it is the contract.
- **Fake collaborator.** A fake, stub, mock, or stand-in that the test or the project builds to imitate a collaborator: a local server that answers like a third-party API, a fake `ssh` or browser early in PATH, an in-memory store in place of the real one, or a mock object. It proves only that the code matches the fake. "Cross the real boundary" says what replaces it.
- **Fabricated fixture.** A fixture hands the code what its production owner should produce, such as a receipt, an acknowledgement, an admission decision, a callback order, or a row in a store path the code never writes. The test then proves the code accepts a world that cannot occur.
- **Capability-flag assertion.** A capability flag asserted in place of the delivery or acknowledgement the flag promises.
- **Call-count or call-order assertion.** It asserts how often or in what order a collaborator was called. It stays only when the interaction itself is the contract (a webhook that must fire exactly once, a lock that must release before retry). Most call counts are implementation detail, not behavior.
- **Misaimed negative test.** A rejection test that passes because an unrelated guard rejected the input first, or that asserts a rejection the production code never reaches. A negative test fails at the guard it targets. Prove that by removing that guard and seeing the test fail. Before an assertion that something is absent, such as no row, no request, or nothing shown, observe a positive signal that the state it covers was reached: the answer that arrived or the job that settled for an assertion after the work, or the in-progress state held for an assertion during the work. Without that signal the assertion passes before anything started.
- **Tombstone test.** It asserts that removed code, a removed file, or a removed feature stays gone. Bringing the thing back would be a decision, not a regression, so the test has nothing to catch. An absence that a user, client, or attacker observes is a contract and stays, such as a retired route that must answer 404 or 410, or a removed permission that must refuse; that test sends the real request.
- **Source-text test.** It reads source text or file structure to enforce a coding rule. That is a linter's job. Add a lint rule instead, unless the repo has no lint hook for that rule.
- **Coverage-chasing test.** It is written to raise a coverage or mutation number. The number is not the requirement.
- **Duplicate test.** It duplicates an assertion another test already makes. It proves nothing new and costs maintenance forever. A test is a duplicate only when every regression its assertions catch also fails another test. One regression caught elsewhere is not enough, because the test can still be the only one that fails for another regression.

## Contracts that stay

A test of an independent contract stays even when it is static, slow, or reads a file. Independent contracts are API, protocol, config, migration, storage, security, and default-value contracts, generated artifacts a consumer reads, and observable ordering. Such a test is not tautological when it checks one artifact against a second artifact that is maintained on its own, because either side can drift alone.

The worked example is the backup table coverage test. It migrates a database and checks every table the migrations create against `BACKUP_TABLES`. The migrations and the list are written separately, so a new table without a backup entry fails the test. A test that asserts `BACKUP_TABLES` equals a copy of itself pasted into the test is tautological, because the copy can only drift by hand.

Reading a file stays allowed when the bytes are the contract a user or consumer sees, such as a config key, a prompt, a route path, a JSON catalog, or a generated bundle, and the check survives a rename of internal identifiers. Reading source code to check its shape is a lint rule's job.

Tests that run production code against an independently specified outcome also stay, including controlled failure orderings, concurrency races, malformed input handling, privacy or redaction completeness, and config rejection at startup. They bring the case about through real boundaries, such as a damaged file in the real state folder, a lock held by a real second process, or a made-up token the real service refuses. A race test observes the overlap it claims, through a real blocking point such as a lock a second process holds or a request body held half sent, or through a check inside the test, because two requests started together can still run one after the other and pass. When no such point exists, the race stays unproven and is recorded as "Cross the real boundary" says. A case that only a fake collaborator can produce stays unproven, as "Cross the real boundary" says.

## Cross the real boundary

Tests use no fakes. A test crosses every boundary its claim depends on for real: a real database in a container, the real HTTP service, the real queue, a real SSH server, the real file lock. A local runtime or emulator that a vendor ships for its own service counts as real, such as `wrangler dev` for Workers and Workers KV, because it runs the vendor's code rather than an imitation the test built.

Reach a third-party service without an account by sending it input whose real answer is the behaviour under test: a made-up token that the sign-in service refuses, or a proxy setting that points at a closed local port, with `NO_PROXY` and `no_proxy` cleared, for a network failure. An invented answer passes while production fails: a `.github/workflows/release.yml` route that returns 404, a job named `build-push` that GitHub lists as `build-push / build-push`, a job log read as a zip that GitHub serves as text.

A test that claims no outside connection runs where the connection cannot succeed, such as a network namespace that holds only the loopback interface, and has a positive control: an attempt the test itself makes, over each transport the product can use, that the recorder must show. Ambient environment changes where a request goes: an inherited `NO_PROXY` sends it around a refusal proxy, and an exported API token makes the code call the real service. Set or clear those variables in the test's own environment.

When no real run can reach a contract, such as one that needs a signed-in account, the contract stays unproven. Delete the test that faked it, and record the contract as unverified where the repository describes its tests, such as the README, and in the PR body. A fake is never the fallback. The record is a claim, so attempt the real run before you write it, rerun any probe result you copy into it, and name the input the attempt lacked (an account, a credential, a service), because a record whose reason does not hold hides a contract a local run can prove.

The clock is the one thing a test may set: with the test runner's mock timers, a clock that production already passes in, or a patch that replaces only the current time while the real time-zone data and parsing run. State keyed to a clock bucket, such as a per-minute limit or a UTC day, needs both a window that cannot end during the test and a key that no other test and no second copy of this test uses ("A test owns its resources"). Freeze the clock for that, or start the test in a fresh window when the clock belongs to a real process that the test cannot freeze, because a run that crosses the boundary, or shares the bucket with another test, changes the count.

Production code carries no test-only seam: an export, flag, wrapper, getter, reset hook, global, or injection parameter that only tests use. Move the proof to the real boundary and remove the seam with the test that needed it. An injection parameter stays when production passes a real implementation through it. Many private controls in one module point to an owner split across too many places, not to a need for more exports.

## Unlanded code runs on scratch state

Run a test or a probe of code that has not landed with `HOME`, the XDG folders, and the app's own state folder pointed at a scratch folder, because unlanded code can damage the real home config, the real database, or a running install. Give a launcher-based end-to-end run ("Choose the verification") the same scratch folders. The run writes nothing to that live state, opens none of it read-write, and starts no server against it. Reading live data, or copying it into the scratch folder, stays allowed. The "real state folder" of "Contracts that stay" is the app's own path under that scratch home. A repository whose proof is a run on a real host, such as a deploy of a system configuration, names that run in its own testing policy.

## Wait for the state the assertion reads

When work finishes after the action that starts it returns, the test waits for the state its assertion reads: the row, the message, or the event the product emits. It polls a state it can read again, or awaits a one-shot event, with a deadline, and its failure message shows the last state seen. A fixed sleep guesses how long the work takes, and the return of the action that starts the work does not show that the work is done. A call that returns its result needs no wait. A fixed delay stays only where the delay is the input under test, such as a slow command that must hit a timeout.

## A test owns its resources

A test takes each resource that a second copy of it could claim from the operating system, or names it with a random suffix: a listening port, a database, schema, container, or queue name, a temporary folder (`mktemp -d`), and a lock or state file. The copies that `flaky-load.md` starts at once, and a parallel test runner's workers, then share no state. Done when two copies of the test file run at once and both pass with the same number of tests.

A listener binds port 0 itself, and the test reads the port from the listener: its return value, its ready line, or its API. A separate server that accepts only a port number gets a socket the test already bound, where the server supports that, such as systemd socket activation. Otherwise the short race between picking a free port and the server's bind stays, and a bind error from it is a collision between runs, not the product's failure.

A test whose contract is a fixed port or name, such as the default port the product documents, runs each copy in its own network namespace or service instance. When it cannot, the repository's testing policy lists the test file as one that runs one copy at a time.

## Changing and deleting existing tests

When you touch a test file, apply the single test to the tests in it. Each test ends in one of four states: retained, repaired, consolidated into a named owner, or deleted. A test being green is not a reason to keep it, and the number of deleted tests is never a goal.

- **A deletion records the proof that remains**: the owner test that still catches the regression, or the reason no contract exists. Without that record, keep the test. When the remaining proof sits in another file or at another layer, confirm it with a mutation for each regression the deleted test caught, and run the full suite on each. Reading the owner is not enough, because a guard that runs before the branch the reader followed can answer first. A reviewer who did not write the change reruns each such mutation in a scratch checkout of the final diff when the proof is local and bounded, and otherwise marks it unconfirmed with the reason, because a writer's record can name an owner that does not catch the regression.
- **A deletion takes its test support with it.** Remove the fixtures, helpers, exports, and dev dependencies that only the deleted tests used, and run the repository's dead-code check when it has one, because a removed test leaves them with no reader and no check that fails.
- **A failing test may be a product bug.** Reproduce the failure. If the code is wrong, the test stays; fix the code in this task or record a follow-up, never delete the test to get green.
- **A test skipped for a known product bug proves itself against a simulated fix.** Apply the smallest correct fix in a scratch copy, run the test unskipped, and see it pass; without the fix it fails at the assertion for that bug. A test that a correct fix cannot turn green, such as one whose setup reuses a one-time code the fix will refuse, gets repaired before it is skipped. Run the file's other tests against the same fix too: a test whose refusal would now come from the new guard instead of its own no longer proves its contract, so aim it before the fix lands.
- **A repair or consolidation proves itself with a caught mutation.** Name the regression and the assertion that must catch it. Introduce that regression in the production owner, see that assertion fail after setup succeeded, restore the source byte for byte, and see the test pass. An import, compile, fixture, runner-timeout, or unrelated-guard failure does not count; a failure at the named assertion does, including its own polling deadline. When no test at a real boundary catches the mutation, check whether the mutated line changes behaviour at all: a dead branch, a guard that an earlier guard makes unreachable, or a setting equal to the default is removed from the product, not covered by a test. A live branch that no test catches gets the missing scenario at its owner.
- **A flaky test gets reproduced in its original order first, then under the gate's load.** Order-only failures usually mean shared state that an earlier test left behind. Failures only under load usually mean the test waits on a proxy, such as a status row written before the work it names starts; wait for the event the assertion depends on. When the original order does not reproduce the failure, follow `~/.claude/shared/flaky-load.md` to reproduce it under load. Fix the shared state, the wait, or the producer. A retry, a serial pin, a quarantine list, or a longer fixed wait hides the cause. A skip stays only under the bullet above on a known product bug, with its simulated-fix proof.
- **A fix for a flaky test is confirmed under the condition that reproduced the failure.** Run the command that reproduced the failure again, with the same order, copies, and loops, and with the result caches off as "The artifact" says. A run is one execution of that command. Make at least 30 runs, and at least three times the number of runs up to and including the first failure, and see every run pass, because no failure in n runs bounds the failure rate below about 3/n at 95% confidence (the rule of three, a good approximation for n above 30). Copies that run at once are not fully independent, so the bound is approximate. A failure in these runs sends you back to the diagnosis. When the failure was never reproduced, the fix stays unconfirmed, so report the conditions tried and the clean runs, and claim no bound.

## Report format

When a task produces or changes tests, or claims end-to-end verification, the final message includes:

- Each test, one line per test: the requirement it proves, then the regression it would catch. A test that cannot fill that line is deleted before the report, not reported as-is.
- Each deleted test, with the proof that remains or the reason no contract exists.
- Each repaired or consolidated test, with its caught mutation.
- For end-to-end verification, the scenario in one sentence, why it is medium or hard, the rerun command, and the artifact path.
- For isolated tests, the failure list written before the code.
- For a bug fix without a new test, the existing test that covers it or the reason no test was added.
- For a fix to a flaky test, the command and the condition that reproduced the failure, the number of runs after the fix, and the failures among them, or "unconfirmed" with the conditions tried.

## Enforcement

Lint rules reject the patterns a parser can decide, such as a test with no assertion, an assertion that compares an expression with itself, a test that asserts on source text, or a committed focus marker (`.only`, `fit`, `fdescribe`), which makes the runner skip the other tests while the run can still pass. Add such a rule to the repository's lint config when it repeats, or turn on the runner's own setting, such as Playwright's `forbidOnly` or Vitest's `allowOnly: false`. The change's one review judges everything else. When a change adds, edits, or deletes tests, fixes a bug, or claims end-to-end verification, that review applies this file: the `code-reviewer` agent (`code_reviewer` in Codex), or another reviewer with this file named in its prompt. It runs once on the diff in its final landing shape, in the order `core.md` (Testing) sets; check each of its findings against the source before you act on it. Do not add a test-admission scanner, a coverage gate, a mutation gate, or a Claude Code hook to enforce this.

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
