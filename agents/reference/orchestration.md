# Orchestration details

Read before you dispatch a `fork` subagent or write a Workflow script.

## Fork subagents

- A `fork` subagent inherits the parent orchestrator's full conversation, including the parent's own dispatch narrative. Without an explicit correction, it can answer as if it were the orchestrator, and a role-confused fork can fabricate findings attributed to sibling agents that never produced them.
- When fanning out fork subagents, state "you are NOT the orchestrator" in each prompt and require the deliverable inline in that same turn. Treat any fork subagent output that references sibling agents' results as suspect, and re-verify a load-bearing claim from a role-confused fork against the source, preferably with a fresh non-fork agent.

## Workflow scripts

- A Workflow tool script's `args` can arrive as a JSON string instead of a parsed object. Guard with `typeof args === 'string' ? JSON.parse(args) : args`.
- Start the script by asserting that each list argument is a non-empty array, and throw with the argument's name otherwise. Pass a list as a JSON value; a file path string is not a list.
- Give each agent a `schema` so its result returns through StructuredOutput; the run's `journal.jsonl` keeps every return value, so the agent writes no report file.
- At most 6 agents run at once (`~/.claude/rules/claude-code.md`); give the workflow more items instead of more concurrency, and the extra items queue.
- In a workflow that loops until a round finds nothing new, cap each round's work so the agent budget still holds one more round after it; a loop that runs out of budget ends with no proof it was done.
