---
name: find-implicit-state-machines
description: Finds the implicit state machines in a codebase (states and transitions spread across booleans, status fields, handlers, callbacks, and timers) and reports a transition table for each, the transitions that are impossible but still reachable in the code, and the non-terminal states with their exits. Reports only. Use when asked to find implicit state machines, to write the transition table of a status field, lifecycle, or workflow, or to list non-terminal, stuck, or impossible states.
---

# Find implicit state machines

An **implicit state machine** is a set of states and transitions that no single place declares. They are spread across booleans, status fields, handlers, callbacks, and timers. This skill writes each one down as a transition table, because the table shows the conflicts the scattered code hides: flag combinations that should be impossible, transitions nobody intended, and states with no way out.

The run reads code and reports. A check you run to confirm a finding stays in a scratch folder outside the repository, and the report names it. Making a machine explicit is a later request, which the caller makes after reading the report, so the repository and its tracker stay as they are.

## Terms

- **State variable**: a value that decides what a unit may do next. A boolean, a status or phase field, a nullable timestamp or error, a timer or request handle, or whether a row or file exists.
- **State**: one combination of a machine's state variables that the domain names or the code tests for. When the code derives the state from several stored values, the table uses the derived name and the report lists the stored values as state variables.
- **Writer**: a line that changes a state variable. An assignment, a setter call, an update or delete statement, a default on creation.
- **Event**: what makes a writer run. A user action, a response, an error, a timer, a retry, a teardown, a message, a restart.
- **Guard**: the condition a writer checks before it writes, as far as it limits the current state. A condition on another value, such as a held claim, counts when it implies the state; say what it implies.
- **Rule**: a statement of what the domain allows, with its source. Which states exist, which exclude each other, which are final, which order they follow.
- **Sequence**: the ordered events and writers that take a machine from one state to another, each with its file and line.
- **Terminal state**: a state a rule means as an end. A machine that a rule means to repeat, such as a lease or a connection, has none.
- **Stuck state**: a non-terminal state that no transition leaves, or whose exits a sequence can lose, such as retries that run out.

## 1. Scope and rules

Use the scope the caller gives, and the whole application when the caller gives none: the code that ships and runs, without the build, test, and deploy tooling around it.

Read what the repository says about that scope before the code: its agent instructions, glossary, specification, and data model. Read whole each document that fits, and leave the others for the search in step 4. Name states and events in the report with the repository's own terms.

Collect the rules while you read, each with its source. A source is a document line, a type or enum definition, a database constraint, a test, or the code's own assumption, such as a reader that handles only some combinations. Step 4 can mark a transition impossible only against a rule, and the caller checks the mark against that source.

Done when you can list the files and folders in scope, the rules collected so far with their sources, and the documents left for the search.

## 2. Find the machines

Search the scope for state variables and group the ones that describe one process into a candidate machine. Each of these signals marks a candidate, so run a search for each one:

- a status, phase, or step field with writers in more than one place;
- several booleans or nullable fields that describe one process;
- a field or module variable that remembers progress between events;
- a queue, job, lease, or stored workflow record;
- a loop written by hand that polls, retries, delays, or saves in the background;
- a flag that some sequences set and none, or only some, clear;
- a cancel, close, or reset that clears some state variables and leaves others;
- an asynchronous result applied without a check that it is still current;
- user interface elements that exclude each other, each with its own flag;
- the same flow written out in more than one place.

An enum, reducer, or declared state machine is still a candidate when a writer bypasses it or a second state variable has to agree with it. A flag that one unit sets, reads, and clears is ordinary state, so leave it out.

Finding a machine is a result on its own, and a machine with no conflict still gets its table.

Done when a search for each signal has run across the scope and every hit belongs to a candidate machine or is ordinary state.

## 3. Write the transition table

For each machine, search the whole repository for every writer of every state variable, by the variable's name and by the name of each helper that writes it, because the writers nobody remembers are the ones that break the rules. Read each writer with the code around it and its callers. A machine whose state is stored also gets the checks under "Stored machines" in this step and the next two.

Write one row per transition, which is a writer, its event, and the states it can start from:

- Writers that perform the same transition share a row that lists each location.
- One writer that serves several transitions, such as a shared update helper, gets a row for each.
- A writer that changes only data inside a state, such as a counter or a due time, gets a row only when a rule or an exit depends on it.
- A row splits in two when a mark applies to only some of its From states.

The columns:

- **From**: every state in which the writer can run. The writer's own guard narrows it. A limit that only a caller or the screen supplies narrows it too, and that limit also goes under "Tried and blocked" in step 4. Write `any` when nothing narrows it, and `none` for a writer that creates the record.
- **Event** and **Guard**: as the code has them. Write `none` for a missing guard.
- **To**: the state after the write. When one event runs several writers, name the state after each, because an early exit between two of them leaves the machine in the state between.
- **Performed at**: the file and line of the writer itself, never of the function that contains it. When one writer serves several transitions, add the line of the caller that picks each. Copy each line number from tool output of this run, with each file numbered on its own.

A transition that the clock performs, such as a lease that expires or a record that becomes due, has no writer. Give it a row whose Event is the time passing and whose Performed at is the line that compares the stored time.

Done when every writer the search found has a row or a line under "Writers without a row" that says why.

## 4. Mark what is impossible but reachable

For each machine, first search the documents step 1 left unread for the machine's terms, and add the rules you find.

Test each rule against the table in both forms:

- a transition the rules forbid, such as one that leaves a terminal state, skips a required state, or runs backward;
- a combination of state variables the rules forbid. It has no row, so name it by its values.

For each one, look for a sequence that reaches it:

- a writer whose From is `any`;
- two events that interleave: a second submit, a response that arrives after a cancel, a timer that fires after teardown, a retry after a success;
- one event with several writers that stops between them, on an error, an early return, or a reset that clears only some state variables.

Then try to disprove the sequence. Check the guards of every caller, controls that are disabled or hidden, locks, transactions, conditional writes, and constraints. Sort what you find:

- **A sequence that survives** gets a mark and its evidence: the rule and its source, each step with file and line, what you checked that does not block it, and the effect, which is what a user sees or what the stored data holds afterwards.
- **A sequence that only a convention blocks**, such as the order of today's callers or a control the screen hides, gets one line under "Tried and blocked" that names what blocks it, because it opens again with the next caller.
- **A sequence blocked by a guard at the writer, a lock, or a constraint** needs no line.

| Mark | Meaning |
| --- | --- |
| `impossible, reachable` | You read every step of the sequence in the code and found nothing that blocks it. A step that is an ordinary action of a user or caller counts as read. |
| `impossible, unconfirmed` | One step depends on something you could not read or decide, such as a framework's ordering, a runtime timing, or how an outside system behaves. Name that step. |

A mark says the code is the wrong side:

- A rule taken from the code's own assumption is weaker than a written one, so say `inferred` beside its source.
- When the code looks deliberate and the written rule is the stale side, leave the mark off and report the document under "Other findings".
- When a document records the sequence as an accepted risk, keep the mark and cite that document.

Done when every rule has been tested against every row of its machine, and each sequence you tried has a mark, a "Tried and blocked" line, or a block at the writer.

## 5. List non-terminal states and their exits

For each non-terminal state, list the rows that leave it and what fires each one. Give each state the first verdict that fits, in this order:

1. `exits`: at least one exit needs nothing from outside the code and its user, such as an action the screen offers, a call that returns or times out, or a timer that survives a restart.
2. `waits`: every exit is the normal next event from outside, such as an answer from another system, and the code sets no deadline for it. Name the event.
3. `stuck: exit not guaranteed`: an exit exists, but a sequence loses it. Name the sequence, such as an error that skips the reset, retries that run out, or a timer held only in memory that a restart drops.
4. `stuck: no exit`: no row leaves the state, and a rule says something has to. A cycle that no row leaves counts the same way when a rule says the machine has to reach a terminal state.
5. `end unclear`: no row leaves the state, and no rule says whether it is an end. Name the evidence that is missing.

A stuck verdict stays when a document records the state as an accepted risk; cite that document.

Done when every non-terminal state of every traced machine has one of the five verdicts.

## 6. Check and report

Before you report, open again every line cited in a marked row or a stuck verdict and confirm that it does what the row says: the write, the time comparison, or the caller's choice. Correct the row when it does not, and remove a mark whose sequence no longer holds, then check the changed rows the same way.

Every candidate is owed a table, so cover the scope this way:

- **With read-only subagents**, when one context cannot trace the scope: give each subagent one subsystem, its candidates, and this skill. A machine belongs to the subsystem that holds most of its writers. The candidate list is a floor that the subagent adds to. Each subagent returns its machines as sections of the template below. Open the cited lines of every mark they return before you report it.
- **Without subagents**: trace stored machines first and then the ones with the most writers, for as long as you can still read every writer in full. A table built from skimmed writers hides the conflicts this report exists to show.
- **Not traced**: list every candidate you did not read in full, with its state variables and location, so a later run can start from that list.

Give the report in the reply, or in the file the caller names. This template binds; the rows in it are examples of the shape, and a heading or line with nothing to say is left out.

- Owner is the file or folder that holds most of a machine's writers.
- The two mark columns count sequences, so one sequence that crosses several rows or machines counts once, under the machine whose writer breaks the rule.
- The stuck column counts the states with a `stuck` verdict. When several states are stuck for one cause, say so in one sentence under the table.
- A sequence with either mark goes under "Impossible but reachable" with its mark named. A forbidden combination starts with its values where a transition starts with its row.

````markdown
# Implicit state machines: <scope>

Searched: <files and folders>. <n> machines traced, <n> candidates not traced.
Rules read from: <documents and definitions read whole>. Searched only: <documents>.
Checks run: <command and scratch folder of each check>.

| # | Machine | Owner | Impossible, reachable | Impossible, unconfirmed | Stuck states |
| --- | --- | --- | --- | --- | --- |
| 1 | Upload | `path/to/upload` | 1 | 0 | 1 |

## 1. Upload

State variables: `status` (`path/to/model:12`), the request in flight (`path/to/client:52`).
States: draft, sending, sent, failed, cancelled. Terminal: sent, cancelled (`docs/uploads.md:12`).

| Row | From | Event | Guard | To | Performed at | Mark |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | none | form opened | none | draft | `path/to/model:12` | |
| 2 | draft | submit | none in `submit`; the screen disables the button outside draft | sending | `path/to/form:41` | |
| 3 | sending | response succeeds | none | sent | `path/to/client:77` | |
| 4 | cancelled | response succeeds | none | sent | `path/to/client:77` | impossible, reachable |
| 5 | sending | response fails | none | failed | `path/to/client:81` | |
| 6 | draft, sending | cancel | `status` is draft or sending | cancelled | `path/to/form:58` | |

Writers without a row: `path/to/model:30` copies `status` into the audit record and changes no state.

### Impossible but reachable

- Row 4, cancelled to sent, `impossible, reachable`. Rule: "a cancelled upload is never sent" (`docs/uploads.md:30`). Sequence: cancel writes cancelled at `path/to/form:58` and leaves the request running; the response handler writes sent at `path/to/client:77` without reading `status`. Checked: no abort of the request, no guard in the handler's one caller (`path/to/client:60`). Effect: the screen shows a cancelled upload that the server holds.

### Tried and blocked

- A second submit while sending. Blocked only by the screen, which disables the button (`path/to/view:20`); `submit` itself has no guard on `status`.

### Non-terminal states

| State | Exits | Fired by | Verdict |
| --- | --- | --- | --- |
| draft | 2, 6 | submit, cancel | exits |
| sending | 3, 5, 6 | response, cancel | exits |
| failed | none | | stuck: no exit. "A failed upload can be sent again" (`docs/uploads.md:14`), and no row leaves failed. |

## Not traced

- <candidate>: <state variables>, `path:line`, <why it was left>.

## Other findings

- <anything else the run showed, such as a document that describes the code wrongly, with both locations>
````

The report is complete when each candidate has its table, its marks with evidence, and a verdict for every non-terminal state. It is partial while "Not traced" names a candidate, and its first line then says so.

## Stored machines

A machine whose state is stored, such as a job, a queue item, a lease, or a status column, has more events and weaker guards than one in memory. Apply each of these in steps 3 to 5:

- **Writers outside the main flow**: migrations, scripts, administrative actions, scheduled sweeps, and other services write the same field.
- **Restart**: a process that stops between two writers leaves the stored state between them. Find what continues the work after a restart. When nothing does, that state is `stuck: no exit`.
- **Concurrent and repeated delivery**: two workers, a duplicate message, or a late result run the same writer twice or out of order. A guard holds against these when the check and the write sit in one conditional write, or under one lock that every competing writer takes. A read followed by a separate write with neither is a guard with a gap.
- **Transport end and domain end**: an acknowledged message, a returned response, or an elapsed timeout ends the transport. The domain state needs its own writer, so check that one runs.

Done when each stored machine has a result for each of the four checks, as a row, a mark, a verdict, or a line that says the check found nothing.
