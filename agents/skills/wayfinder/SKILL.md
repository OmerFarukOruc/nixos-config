---
name: wayfinder
description: >-
  Use when the effort is too big and foggy for one plan; chart a multi-session
  map of DECISION tickets, not build tickets.
---
# Wayfinder

Chart a huge, foggy effort as a **shared map of decision tickets** on Linear. Finding the way is the job. Charging at the destination is not.

You are the **planner** (and interviewer when a ticket is grilling). The **Linear writer** is the only role that creates or edits Linear issues. Other roles may read.

## Plan, don't do

Each ticket resolves a **decision** (a question whose resolution is a decision), not a slice of a build. The map is done when the way is clear and nothing is left to decide before someone goes and does the thing.

**Notes** on a given map may override this and carry execution onto the map. Absent that override, produce decisions, not deliverables.

Never mix implementation tracer-bullets onto this map.

## When not to make a map

1. Name the destination (grill if needed).
2. Fan out breadth-first across the space.
3. **If this surfaces no fog** — the way is already clear and the journey fits one session — **do not make a map**. Stop and ask how the human wants to proceed (usually a single plan, which the human can write with the crystal-plan skill).

## The map artifact

One **parent** Linear issue, labelled `wayfinder:map`, in the Linear team that the repository's `.linctl.toml` pins, under the outcome issue. Children of that parent are the tickets.

The map is an **index**, not a store. A decision lives in exactly one place: its ticket. The map never restates a decision; it gists closed ones and links.

**Do not list open tickets on the map.** They are open child issues, found by query. The frontier is: open + unblocked + unclaimed children.

Refer to every map and ticket by **title** (the name may wrap a link). Never a bare id, number, or slug in narration or in Decisions so far.

### Map body (only these sections)

```markdown
## Destination

<one or two lines: the spec, decision, or change this effort is finding its way to>

## Notes

<domain; skills every session should consult; standing preferences; any "do, don't just plan" override>

## Decisions so far

- [<closed ticket title>](link): <one-line gist of the answer>

## Not yet specified

<in-scope fog you cannot ticket yet; graduates as the frontier advances>

## Out of scope

<work ruled beyond this destination; closed, never graduates>
```

**Decisions so far** lists **closed tickets only**, title + one-line gist. Open work stays off the map.

### Fog vs ticket vs out of scope

| Bucket | Test |
|--------|------|
| **Ticket** | The question is already sharp, even if blocked. |
| **Not yet specified** | You cannot yet phrase it that sharply. Do not pre-slice fog into ticket-sized pieces. |
| **Out of scope** | Past the destination. Scope, not sharpness. Close any mis-scoped ticket and leave one line here (gist + why), not in Decisions so far. |

## Tickets

Each child issue body is **`## Question` only**. The answer lives in a **resolution comment**, not the body. Size the question to one fresh context window.

Label each child with exactly one type:

| Type | When | Who |
|------|------|-----|
| `research` | A fact a decision waits on (docs, third-party APIs, local knowledge). | AFK. May resolve several research tickets in one session, in parallel. |
| `prototype` | "How should it look / behave" that talking cannot settle. Cheap artifact; link it as an asset. | HITL. |
| `grilling` | Conversation. The default. | HITL. Interviewer runs grilling. Never answer for the human. |
| `task` | Manual work that **unblocks a decision** (access, a signup, moving data so its shape can be seen). Does **not** deliver the destination. | HITL or AFK. |

Claim a ticket by setting Linear **assignee** before any work. An open unassigned ticket is unclaimed.

Blocking uses Linear's **native** `blockedBy` / `blocks` relations so the frontier is visible in the tracker UI.

## Session rules

- **Never resolve more than one ticket per session**, except `research` tickets.
- Charting the map is one session: name destination, sketch fog, create map + currently-specifiable tickets, wire blocking in a **second pass** (issues need ids before they can reference each other), fire research in parallel, **hand-resolve nothing**.
- Working the map: load the map at low resolution → take the named ticket or the first unclaimed frontier ticket → claim it → resolve (zoom related closed tickets on demand) → resolution comment → close → append title + gist to Decisions so far → graduate newly sharp fog into tickets (create-then-wire) → rule newly-exposed out-of-scope work out rather than resolving it on the route.

## Linear writer contract

Only the **Linear writer** publishes or updates the map and tickets. planner/interviewer produce the draft; the writer writes.

- That team only. Never copy other teams' issues. Never seed empty rows.
- Find-before-create. Do not close or rewrite a parent except to keep the index sections honest and to link children.
- No secrets: never put credentials, tokens, personal identifiers, or secret values in Linear. Use opaque ids and hashes only.
- Dates in tracker and handoff prose are DD-MM-YYYY.
- If code is mentioned, inspect it via a cloud agent or remote API. Never tell anyone to clone.

## Done

The way is clear: no open tickets, fog emptied or ruled out of scope, destination still true. Tell the human the route is ready for a build plan, which they can write with the crystal-plan skill when they want one. Do not sneak tracer-bullets onto this map.
