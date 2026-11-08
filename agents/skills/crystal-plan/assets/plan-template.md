<!-- Copy this file, replace every <angle-bracket> cell outside the stop report block, and delete this comment. The finished plan passes every row of references/readiness-checklist.md. -->

# <Imperative title: what is true after this lands>

Readiness: <READY | DRAFT | BLOCKED (smallest missing decision)>
Revision: 1
Repository: <owner/repo> at `<full SHA>` on `<branch>`; local changes: <none | paths>

## Outcome

<The failure or cost today. The behavior after the change. The behavior that stays unchanged.>

Bounds: <who uses it, who operates it, which processes write the same state at once, how much failure is acceptable>

## Sources

- <name> <version>, <URL>, <section> (official | community): <the fact this plan uses>
- <repo URL>@<tag> `<path::symbol>`: <behavior read from the source>
- <or: in-repo only: paths, with the imports checked>

## Current state

- `<path/file.ext::symbol>`: <its role>; <the one fact the plan relies on, true at the SHA above>.
- Convention: `<path/exemplar.ext::symbol>`: <what to copy from it>.
- Document: `<docs/file.md>`, heading `<heading>`: <the rule or sentence the change must obey or update>.
- Terms: <project word> means <definition the executor needs>.

## Decisions

- <One settled interface, default, error, ordering, or state owner, with the reason that prevents the likely wrong build.>
- Out of scope: <path or behavior left alone, and why>.

## Commands

| Purpose | Command (from `<config file>`) | Expected |
| --- | --- | --- |
| Install | `<the install command a fresh worktree needs>` | exit 0 |
| Tests | `<cmd>` | exit 0, <N> passed |
| Gate | `<cmd>` | exit 0 |

## Slices

### 1. <Observable increment>

Blocked by: <none | slice n>
Commit: `<Conventional Commits subject>`
Operator: <none | the deployment or production activation step a person runs, and its rollback>
Touch set: `<path>`, `<path>`
Interface: <none | produces `<signature>` | consumes `<signature>` from slice n>
Behavior:

- <An input and its output, a boundary, a failure, or an invariant. Each line can fail.>

Red: `<cmd>` from `<directory>` drives <the cases>; it prints <the output the planner copied from a run at the pinned SHA, or the expected output followed by NOT RUN>. <Only when Omer requested a new test or the repository requires one: `<test file>::<owner test>` gains the cases, as <the message or issue that asked | `<instruction file>`, heading `<heading>`> requires.>
Change:

1. Run the Install command, then `git diff --stat <pinned SHA> -- <every Current state and touch-set path>` and `git status --short -- <the same paths>`; they print no path outside the touch sets of earlier slices in this plan. <For a file another in-flight branch edits: `grep -n '<symbol>' <path>` prints the symbol.>
2. <Add the required test cases, when Red names any, then> run `<cmd>`; it prints the Red output above. <When Red was observed on a stand-in because the behavior cannot fail at the pinned SHA, this step names the stand-in and runs on it.>
3. <Edit at `<path::symbol>`; what replaces what. Name the exemplar to copy.>

   ```<lang>
   <TARGET, as the readiness checklist defines it. Omit this fence when the edit has an exemplar.>
   ```

4. Run `<the repository's full pre-PR gate on the touched files>`; it exits 0.
5. Commit the touch set with the Commit subject; `git status --short -- <touch set>` prints nothing.

Green: `<cmd>` prints <expected output, including the test names or output lines that prove each Behavior line>
Done when: <observable condition>

## Final gate

<The proof ladder from planning-guide.md, Verification design, in its order, each rung with its command and expected output, and any manual check with its owner and pass condition. Each end-to-end proof names the artifact it leaves: rerun command, captured result path, pass condition. A command that takes minutes gives its measured duration and host, and the faster command that runs after a fix to the code it covers. Name what must be green before the PR, the merge, or the deploy.>

## Stop conditions

- The drift check in Change step 1 prints a path outside the touch sets of earlier slices, or its `grep` prints nothing.
- A change needs a path outside every touch set.
- The Red run in Change step 2 prints other output than the Red line.
- Two sections of this plan disagree, such as a Behavior line and a Change step.
- Green or a Change step's gate still differs from its expected output after one edit to a touch-set path.
- <This plan's own risk: the assumption that, if false, makes the plan wrong.>

On a stop, change nothing more and report in this shape:

```text
Stop: <the stop condition, quoted>
Expected: <the plan text the run tested>
Found: <what the run or the code shows>
Evidence: <the command and its output>
```

## Residual

<P3 findings accepted without an edit, one line each with the row they fail. Otherwise "none".>

## Open decisions

<BLOCKED only: each decision with its options, the evidence for each, a recommendation, and who decides. Otherwise "none".>
