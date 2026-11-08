# Finding format

Write each finding as one block:

```markdown
### [P<0-3>] <consequence-first title>

- Section: <the plan section, with a short handle for any ID it uses>
- Confidence: <50 | 75 | 100>
- Class: <fix | decision>
- Consequence: <what goes wrong for the builder or the system if the plan stays as it is>
- Evidence: <a short quote from the plan, and the path:line or command output that shows the problem>
- Change: <the one change that resolves it; for a decision, each option and the recommended one>
```

## Severity

- **P0**: the approach as a whole is wrong, or a core acceptance criterion is missing.
- **P1**: a gap that will stop the build or produce the wrong result.
- **P2**: a worthwhile local correction.
- **P3**: a minor improvement.

## Confidence

- **100**: you confirmed it in the code or the plan text, and it will happen every time.
- **75**: you checked it, and it will be hit in practice; full proof needs something you could not run.
- **50**: a verified concern below the bar for action; it goes to FYI with its benefit stated.

Below 50 is not a finding.

## Class

- **fix**: one right change follows from the plan's outcome and its settled decisions. Choosing between equivalent ways to build it is still a fix.
- **decision**: only the owner can settle it. It reverses or changes a settled decision, adds machinery the bounds do not demand, changes what gets built, or needs a fact nobody can find in the plan, the code, or the docs.

## Change

The change commits to one action, or to one named combination of actions. A list of options to pick from later belongs to a decision, never a fix.
