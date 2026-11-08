---
name: quality-campaign
description: Run a repo quality campaign end to end. Council review, a GitHub issue campaign, an external spec gate, then orchestrated implementation by cheap writers.
disable-model-invocation: true
---

# Quality campaign

Deliver a repo-wide quality campaign in two stages, normally two sessions:

- **create**: review the repo with a council of models, verify every finding, publish a GitHub issue campaign, pass the spec gate. Read [references/create.md](references/create.md).
- **orchestrate**: execute a published campaign. One writer per slice in its own worktree, reviewed slice by slice, merged into an integration branch, landed on the default branch. Read [references/orchestrate.md](references/orchestrate.md).

Route by the argument. `create`, or no published campaign: create route. `orchestrate #<parent>`, or a parent issue reference: orchestrate route. Ask when neither fits.

Roles. Every reference uses these exact words:

- **council**: the independent external review models in the create stage.
- **writer**: the CLI coding agent that implements one slice.
- **spec gate**: the external adversarial reviewer of the published campaign.
- **slice**: one subissue, one worktree, one writer.
- **verdict file**: the written record that authorizes a scope exception or carries review findings back to a writer.

[references/bindings.md](references/bindings.md) holds the current tool and model bindings for every role. Read it before dispatching any external process. The route references never name external tools or models.

## Invariants, both routes

- Audit every progress claim against a tool result from this session. Say what is not yet verified.
- Check every external CLI's flags with `--help` before its first use in the session. The bindings file may lag reality.
- Severity and acceptance come from reproduced evidence, never from which model reported a finding.
- Tests in every slice follow `~/.claude/shared/testing-discipline.md`, and that file wins where a reference here says something different about tests. Name it in each writer's prompt.
- Apply the necessity test to every finding before it becomes work. Rejecting a finding with a recorded reason is a normal outcome.
- Stay local. Push, PR creation, squash merge, and any direct commit to the default branch are each a separate user authorization.
- Run long external processes as `run_in_background` Bash and keep working, because the harness notifies on completion and the output file stays readable mid-run. Use tmux only for work that must survive this session.
- Measure machine resources live before each dispatch batch. Never pre-commit to a concurrency number or a resource threshold.
- End every stage report with the parent issue URL.
