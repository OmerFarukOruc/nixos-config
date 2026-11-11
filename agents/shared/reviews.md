# Reviews, audits, and closing work

## Reviews and audits

- In a review or audit, read entire files before a verdict. Record the merge-base and head commit SHAs for a branch review, and review that fixed comparison. Recheck the head before reporting and reconcile any movement. When the target is a plan, spec, report, or PR body, check its numbers, dates, and names against each other and quote each contradiction with its location. Rerun each load-bearing number from its named source and check that the query measures what the label says: a step or a job, a per-run share or a pooled total, a filter that drops cases. A number labelled "test job 24.1 min" whose script takes the median of a step's durations is wrong until relabelled "test step".
- When a plan or handoff supplies a patch that deletes Python tests or dead code from a list, check the patch with `removed-defs <base> <head> --ids <file>`. Compare its lists with the plan and read the entries under `read these`; the deleted hunks then need no line-by-line read. The command shows what the diff removes. It does not show that a removal is safe or that no helper is left unused, so the cover check and the unused-name check stay. Read every other diff in full.
- When a change skips, carries over, or removes a check, its review names the failure that check caught and what catches that failure now. A docs-only skip that removes master's re-run of the tests must say which check still catches a file missing from the path list.
- When a change adds a step or a check to an unattended path (a timer, a bot's commit, a hook that runs on such a commit, agents left running while Omer is away), its review names what happens when that step fails and who sees the failure. Before leaving agents running on devbox while Omer is away, read `~/.claude/reference/unattended-agents.md` for each known failure point and what handles it.
- When a change hardens one copy of a repeated pattern, search for the other copies. An unhardened copy is a finding in the same review.
- A change gets one review, on the diff in its final landing shape. When review fixes change the landing shape, check only what `git range-diff` shows changed yourself. When Omer asks for a new scope or design after the review, the rewritten diff is a new change and gets its own review.
- A many-agent adversarial review of a diff that already passed a normal review chain has so far found proof gaps and doc drift, not bugs. Run one only when Omer asks.
- Confirm a check-then-act race across two connections or transactions as a bug only when a feasible interleaving produces an invalid state or unintended side effect and no structural guard prevents it. Treat idempotence as counterevidence only when it prevents that specific outcome. Without a demonstrated invalid outcome, report the unresolved concern as a design smell.

## Closing issues

- Close an issue or a planned unit as covered only when the run, or the file and line, shows every clause of its end state. A residual that the evidence itself names keeps it open.
- When a PR fixes part of an issue's checklist, rewrite the issue body to hold only the open items, each restated with its current state, and one line naming the PR that fixed the rest.

## Benchmarks and measured optimizations

- Before a benchmark that uses a solver or a browser, confirm their actual settings; an altered harness is not production evidence. A proof never creates an environment implicitly; use an existing one or clean generated state. A redirect, login page, or unavailable service is not UI evidence.
- When reporting a measured optimization, separate automated runtime from operator time, break it down per phase, and disclose any regression.
