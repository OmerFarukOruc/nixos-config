# Maintaining enhance-prompt

For whoever edits `SKILL.md` in this folder. The skill itself does not load this file.

- A new rule fixes a live failure: a run where the skill wrote a worse prompt than the rule would give. The commit message that adds the rule names that run, its draft and what the prompt got wrong, so a later reader can tell which rules still earn their lines.
- After each edit, run Claude Code's `/doctor` prompt audit on `SKILL.md` and remove each line it shows nothing needs any more.
- Check the change with a live `/enhance` run on a draft the rule applies to, and on one it should leave alone.
