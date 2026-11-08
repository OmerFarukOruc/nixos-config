# Plan review checks

Run every check against every step of the plan. Judge each one against the plan's own outcome, criteria, and bounds.

## Holds together

- **Complete.** Every acceptance criterion has steps that deliver it and a verification that proves it. No step leaves behaviour undefined.
- **Buildable.** Each step names a concrete anchor (a file, symbol, command, or file to create) and is specific enough to do without stopping to decide something the plan should have decided.
- **Ordered.** Each step's prerequisites come before it; no dependency is circular or missing.
- **Accurate.** What the plan says about the current code (paths, symbols, signatures, data shapes, module boundaries, interfaces) matches what you read. A wrong claim about the code misleads a builder most.
- **Consistent.** No two sections disagree: steps and verification describe the same behaviour, and one thing keeps one name.
- **Verified for real.** Verification names the command or check and the result it expects. A test it proposes or keeps fails when the behaviour it guards breaks: it reads a surface the code writes, no other mechanism produces the same result, and it does not replace the code under test with a double.
- **Gates read what they gate.** A step that waits for a signal (a green run, a passed check, a quiet period) names the check and what that check reads. A check that never reads the environment or data the step changes cannot release the step.
- **Follows the codebase.** The approach uses the patterns and helpers the repository already has, or says why not.
- **Side effects.** Changes to shared code (helpers, hooks, globals, schemas) name the other callers they affect.
- **Failure modes.** Partial failure, retries, stale state, rollback, and data loss are handled for the scenarios the bounds allow. A scenario the bounds rule out is not a gap.

## Right size

- **In scope.** Every step serves an acceptance criterion or a bound. A step nothing asks for is a finding: an unrequested feature, an abstraction with one user, or scaffolding for later work.
- **Proportionate.** Machinery (a lock, lease, queue, retry policy, state machine, version scheme, or new stored entity) matches the failures the bounds admit. Adding such machinery is an owner decision.
- **Not self-justified.** A mechanism justified only by a failure that the mechanism itself creates is a finding; cut it and see what falls away with it.
- **Simplest safe approach.** When a simpler or safer approach gives the same outcome, name it and its concrete advantage.
- **Nothing harmful left out.** For what the plan defers or excludes, ask what happens when that failure occurs and who notices. Harm that lands before anyone can catch it is a finding.
- **Not narrowed.** The plan delivers what was asked; a guard that delays, caps, or skips requested behaviour is a finding.

## Survives reality

- **Assumptions.** Name what the plan assumes about the environment, tools, data volume, timing, and order of events without saying so, and what happens if each is wrong.
- **Foundational decisions.** For each decision others depend on, say what evidence would prove it wrong and what reversing it would cost. High cost with weak evidence is a finding.

## Not findings

- Wording, formatting, and style preferences.
- An alternative with no concrete advantage over the plan's choice.
- A preference against a settled decision. Report a settled decision only with evidence that it cannot reach the outcome.
- Speculation with no current signal: growth with no numbers, an edge case with no path to it.
- Anything a linter, type checker, or the build catches.
- Detail a competent builder derives from the plan and the repository in seconds.
- Content the plan explicitly defers, unless leaving it out causes harm nobody would catch.
