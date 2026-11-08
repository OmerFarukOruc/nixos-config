# Planning craft

Read this while gathering evidence and settling decisions. It describes what to find
and why, not text to paste into the plan. The rules a finished plan meets are the rows
of [readiness-checklist.md](readiness-checklist.md).

Sections: Evidence that survives a handoff, Trace the behavior, Choose the smaller
design, Slice the work, What the plan carries, Verification design.

## Evidence that survives a handoff

A planning claim has one of three forms: an observed repository fact with `path::symbol`
and a fact line true at the recorded SHA; an externally verified rule with its version
and official source, found by the docs discovery or source check; or an
open assumption listed under Open decisions. A command found in a config file is a
command, not an observed run; write NOT RUN beside an expectation you did not observe.
A load-bearing shape is a TARGET, and the plan says so.

Read the source contract fully, then the decisive implementation unit, its callers, and
its test setup deeply enough to explain the current behavior. A `path::symbol` with a
fact line in your words survives edits to the file, while a pasted excerpt or a line
number is a claim that drifts and a line the reviewer must check. Keep the required
outcome separate from a reporter's proposed fix, and read older plans as evidence of
past decisions.

## Trace the behavior

Find the entry point, the owner, the state transitions, and the observable result.
Inspect the branch that handles absence, invalid input, failure, and repeated calls.
Name what calls the changed symbol and who consumes its output, and whether another
actor changes the same state.

For a changed interface, trace each caller with the data it actually has and show one
concrete call per caller. Resolve a missing argument with a decision in the plan; a
dummy payload or a nullable field added to satisfy an untested shape is a finding.
Distinguish absent, empty, null, unchanged, and removed when they change behavior.

Requirements name the cases someone thought of. Before you write Behavior lines, list the
inputs the requirement is silent on that the code will still meet: absent, repeated,
oversized, malformed, and concurrent. Give each one a Behavior line or an Out of scope
line, because a cold executor proves only the cases the plan names.

For a bug, separate the symptom from the cause: give the minimal reproduction through
the real program and the code-level causal chain, name the competing explanation the
reproduction rules out, find the existing test that should have caught it, and pick the
smallest fix boundary. For a behavior-preserving refactor, name the contracts and the
existing tests or runs that keep it a refactor. Removing code needs evidence from
callers, runtime registration, configuration, and tests; an empty text search alone is
not proof.

## Choose the smaller design

Consider, in order: doing nothing, removing a step, reusing an existing primitive,
changing configuration, a local extension, and only then a new layer. Name the invariant
a new abstraction, dependency, state machine, cache, or shared store protects, and keep
it only when a requirement or a demonstrated risk needs it. Compare the meaningful
alternatives and choose one; the executor selects no library, transaction boundary,
response shape, or error semantics.

A conditional step is fine for a small, finite, observable environment branch (one
command per supported OS). Unresolved architecture is not a branch: settle it with
authorized research or an isolated experiment, or mark the plan BLOCKED.

## Slice the work

A slice is one meaningful increment a fresh reviewer could accept on its own and that
ships alone with CI green. Split only where a reviewer could accept one slice and reject
its neighbor; fold setup, scaffolding, and documentation into the slice whose
deliverable needs them. Prefer a thin end-to-end path through the layers over a layer at
a time. For a wide mechanical change, sequence expand, migrate in bounded batches, then
contract, each batch its own slice.

## What the plan carries

Pin every consequential choice. The executor writes the implementation. The plan names
`path::symbol`, the data flow, the cases, and the exemplar to copy. Every pasted line is
review surface: a line that fails the formatter, a quote that drifts, a tracker id in a
test, none of which change what the executor builds. Carry what the executor cannot
regenerate from the repository in seconds, and leave out what it can.

"Replace only the body of X" is the edit; the TARGET is the decision-sensitive bytes
inside it. The executor already decides how to implement inside the slice, so a plan
that inlines whole modules does two jobs and gets both wrong.

"Validate input" is complete only with the valid and invalid cases, the failure output,
and the side effects.

## Verification design

`~/.claude/shared/testing-discipline.md` decides what counts as proof, and the Proof
shape row applies it. The artifact matters because the executor and its reviewer are
different agents: a rerun command and a captured result let the reviewer compare
instead of trusting the executor's summary.

Use the repository's own commands, including the full pre-PR gate the contributing
document names. A runner in watch mode never exits, and a filter that selects zero tests
can still exit 0, so either one turns a check into a step that cannot fail.

Red states the intended pre-change output and why it happens; an import error, a missing
dependency, or a broken runner is not the regression unless that failure is the defect.
Green is the same command after the change, with the output that proves the behavior.
When the behavior cannot fail at the pinned SHA, because the page it checks does not
exist yet or the test already passes, observe Red on a stand-in in the red worktree,
such as a scratch page or a reverted line, and say in the Red line which stand-in you
used.

The Final gate is the proof ladder, in order: every slice's Green again, the local gate
(with the tests the repository already has) and one independent review started together,
the review fixes and the gate on the fixed head, the full end-to-end suite or a runtime
rehearsal where the change only shows when the real components run together, CI, and any
post-merge check. Write the delivery boundary as a sentence, for example "no PR until
the paired rehearsal passes after the final commit".

A proof that takes minutes sets the cost of every rerun after it, such as the rerun
after review fixes, which is why the Slow proof row asks for its measured duration and a
faster command for the rerun. Independent parts that run at once, such as the old and
new copies in their own state directories, cut that cost. The paths other processes
change between two compared runs, such as the `/tmp` folders a running test suite
creates, are what the exclusions remove, so a difference that remains comes from the
change and its stop condition needs no judgment.
