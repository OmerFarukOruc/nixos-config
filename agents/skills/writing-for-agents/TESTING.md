# Testing a document

The testing branch of [`writing-for-agents`](SKILL.md): how to show that a new or changed document changes what an agent does. The no-op test in `SKILL.md` is settled here, by a run, not by debate.

## Run it against a baseline

1. Pick one to three real tasks the document is for, including a hard one. Real work beats a made-up scenario.
2. In the same turn, start two fresh agents on each task: one with the document and one without it. For a change, the baseline is the previous version, checked out from git into a separate path.
3. The tester is an agent that did not write the document. An author running its own document already knows what it meant, so its run proves little.
4. Run on the weakest model that will use the document. A line that is a no-op for a strong model can carry a weaker one, and over-explaining slows a strong one.
5. Ask each run to list where the document left it unsure and what it worked around. Those notes show defects even when the output looks right.

When the output is a matter of judgement, such as writing style, an agent that wrote neither version compares the two outputs without knowing which is which. Save assertions for outputs a check can decide, and make each one fail on a wrong output: "the file exists" passes when the content is wrong.

## Read the transcripts

Read what each agent did, not only what it produced. Each signal points to one move:

| Signal in the run | Move |
| --- | --- |
| The agent never reached material it needed | Sharpen the pointer's wording; inline the material only if that fails |
| It read the same disclosed file on every run | Move that material up the ladder, into the entry document |
| It never opened a bundled file | Prune the file, or fix its pointer |
| Every run wrote the same helper code | Bundle that code as a script |
| A line sent it on a detour | Cut the line |
| It ignored an instruction it saw | Give the reason the instruction exists |
| It followed an instruction and the result was still wrong | The instruction is wrong; rewrite it |

Before blaming the document, check that it caused the failure: a run can fail on the task itself.

## Revise

Fix the cause, not the example. A line written to make one test case pass tends to fit only that case; reach for a different leading word, a reason, or a better default instead. Then rerun every task, baseline included, so a fix for one case does not break another. Stop when the runs show no new problems, or when a round makes no real progress.

## Test a description

A description is a pointer, so test that it fires. Write realistic requests that should reach the document and near misses (Anthropic's skill-creator uses 8 to 10 of each) that share its words but need something else; a near miss is worth more than an unrelated request. Run each request a few times, because triggering varies from run to run, and judge a rewrite by requests you did not use while writing it. This needs a headless agent CLI, such as `claude -p` or `codex exec`.

## Where test material lives

Runs, transcripts, and request lists go in a scratch folder beside the document, never inside a skill folder, where the agent finds them while browsing and takes them for instructions.
