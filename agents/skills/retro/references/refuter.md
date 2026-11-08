# Refuter prompt

Fill the four placeholders (the session and agent ids, the skill directory, the findings, and the candidates you dropped) and send the text below as the whole prompt of one new subagent with the description `Refute retro findings`; the digest labels agents with that description as retro refuters. Wait for its answer before you go on. A new agent has not seen the session, so it checks the findings against the transcript instead of against memory. The 40-call limit below is a guess; tune it from runs. When the retro kept no finding, write `none` under Findings and list every candidate under the dropped ones.

---

You check the findings of a retrospective on a coding session. You did not take part in the session. Try to refute each finding against the session's transcript; a finding survives only when the transcript or a command you run supports it as written. Change no file, and run every command in the foreground. Stop after about 40 tool calls, and answer in your final message with the verdicts first.

Transcripts: `<session ids, main session first, then the agent-<id> of any subagent the findings cite>`. Read each with `<skill directory>/scripts/session-digest <id>`, called by its path, for the overview, `--all` when a section list is cut, `--show <line>` or `--show A-B` for entries in full, and `--cap N` when an entry is cut; count with `--grep <regex>`, whose last line counts the matching entries. Read whole entries before you judge; a cut slice hides the line that decides. Cite evidence as `<id>:L<line>`.

Findings:

<numbered findings, each with its claimed evidence as <id>:L<line>, cause, and fix>

Candidates the retro dropped, with the reason:

<dropped candidates, each with its reason, such as "already fixed by <file>:<line>">

For each finding:

1. Open the cited lines and check that they say what the finding claims.
2. Check the cause. Search the transcript for actions the session itself took that explain the event, and for what the user told it earlier.
3. Check that the proposed fix targets the line or file that caused the behaviour, and that no existing rule, check, or open change already covers it.

Then check each dropped candidate's reason the same way. A reason of the form "rule X already covers this" holds only when X was made after the event, or the agent did something other than what X describes; otherwise the rule failed, so mark the reason refuted and name the rule. A fix counts as coverage only when its quoted line would have stopped the event. Read the digest's user messages and error groups once more, and search the session and its subagents for escapes (bugs that a review, gate, or test passed and a later stage caught) with `--grep '(?i)partial review|not (read )?in full|targeted greps|did not (read|run)' --agents` and `--grep '(?i)blocker|regression|should have caught|missed by' --agents`, skipping steering text and verdicts that found nothing. Name up to three frictions or escapes the findings missed, each with its line.

Recount every count a finding states, and check every quantifier it uses (most, all, every) against what you opened.

Answer in three sections, Findings, Dropped candidates, and Missed frictions and escapes, and write `none` in an empty one. Each finding line gives its number, `confirmed`, `refuted`, or `unclear`, and the evidence you checked (line numbers, or the command and its output). A finding where you skipped any of checks 1 to 3 is `unclear` and names the skipped check. Under Dropped candidates, give one line per candidate whose reason does not hold.
