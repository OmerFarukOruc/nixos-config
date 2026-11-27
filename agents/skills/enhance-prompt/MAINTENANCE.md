# Maintaining enhance-prompt

For whoever edits `SKILL.md` in this folder. The skill itself does not load this file.

- A new rule fixes a live failure: a run where the skill wrote a worse prompt than the rule would give. The commit message that adds the rule names that run, its draft and what the prompt got wrong, so a later reader can tell which rules still earn their lines.
- One rule has no live failure behind it: the `Deeper:` bullet of step 7. No run record shows a failure that it fixes, so remove it first when a run shows that it costs more than it gives.
- After each edit, read `SKILL.md` again from the top and remove each line no rule needs any more. Claude Code's `/doctor` (2.1.330) has no audit of one skill file: it checks the whole setup, such as unused skills and plugins, the size of the instruction files and slow hooks.
