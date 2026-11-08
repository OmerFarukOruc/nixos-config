---
name: plan-review
description: "Review an implementation plan against the code it changes before anyone builds it, or merge several reviews of one plan into one verdict. Use when asked to review, critique, or check a plan, or to combine plan reviews."
disable-model-invocation: true
---

# Plan review

A plan review finds what would make a builder do the wrong work or get stuck, and checks every claim the plan makes about the code. It reads; it does not edit the plan or the code. The caller decides what happens with the verdict.

Inputs: the plan, a checkout of the repository it changes, and, from a later round, the earlier reviews with what was done about each finding. Settled decisions are the ones the plan or its caller records as decided by the owner.

## Review

1. **Bind the plan.** Read it in full. Write down its outcome, its acceptance criteria, its bounds (users, operators, concurrent writers, how much failure is acceptable), and its settled decisions. Done when each one is quoted from the plan or recorded as missing; missing bounds or criteria are findings.
2. **Check the plan's facts.** Open every file, symbol, command, and interface the plan names, at the revision it names. Done when each one is marked as matching, different, or absent, with the path and line you read.
3. **Attack the plan.** Apply every check in [rubric.md](rubric.md). Trace each step's happy, empty-input, missing-input, and failure paths through the code you read. Done when every check has been run against every step.
4. **Admit by consequence.** Keep a finding only when following the plan as written gives a wrong result, a failed step, or real rework. Shape each kept finding as [findings.md](findings.md) defines, with its confidence. Drop anything under confidence 50.
5. **Write the review** in the output format below.

## Merge

Use this when two or more reviews of the same plan exist. The reviews are evidence; the verdict is yours.

1. **Verify each finding yourself** against the plan and the code. A reviewer's confidence, severity, or agreement with another reviewer proves nothing. Done when each finding is marked confirmed, refuted with the evidence, or unverified.
2. **Merge duplicates.** Two findings are one when a single fix resolves both. Keep the higher severity and confidence and both reviewers' evidence. When unsure, keep them apart.
3. **Weigh single-reviewer findings.** A finding only one reviewer raised keeps its level only when your own check in step 1 confirmed it; otherwise it moves to FYI.
4. **Respect earlier rounds.** Drop a finding that repeats one already rejected, unless the plan or code changed since. Re-raise one marked as fixed when its evidence is still there.
5. **Classify** each surviving finding as a fix or a decision, as [findings.md](findings.md) defines. When reviewers disagree on the remedy and the plan's decisions do not settle it, it is a decision that names both remedies.
6. **Write the review** in the output format below, listing every reviewer under Coverage.

## Verdict

- `REVISE` when a fix at P0 to P2 with confidence 75 or 100 remains.
- `ASK` when no such fix remains but a decision does.
- `PASS` otherwise.

## Output

```markdown
# Plan review: <PASS | REVISE | ASK>

<One sentence: what the plan builds and whether it is ready.>

## Fixes
<each finding in the findings.md block format, most severe first>

## Decisions
<each decision with its options and a recommended one>

## FYI
<one line each>

## Coverage
<each reviewer, its model if known, and what it checked; findings dropped and why, as counts>
```

Omit an empty section. The first line is the verdict line a caller can parse.
