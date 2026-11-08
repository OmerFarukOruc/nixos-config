---
name: no-comments
description: "Deletes comments from a set of files, a folder, or a repository and fixes the code they excused. Use when asked to remove, audit, or sweep comments; the code-reviewer agent checks the comments each change adds."
---
<!-- Adapted from cursor/plugins pstack/skills/no-comments/SKILL.md at ce649c03ac3b75b6ae80cbd15b7e2c536caedb5a. Copyright (c) 2026 Lauren Tan. MIT License: https://github.com/cursor/plugins/blob/ce649c03ac3b75b6ae80cbd15b7e2c536caedb5a/pstack/LICENSE -->
# No comments

Start the comment-sicko agent on the scope, audit its report, and act on the accepted verdicts. Its fresh read beats yours, so defer to it except where step 2 rejects a verdict.

## Scope

Use the files, folder, or diff the caller names. Otherwise use every tracked file in the repository (`git ls-files`).

## Steps

1. Start an agent with `subagent_type: "comment-sicko"`, passing the scope and a report path in a scratch directory outside the repository. Its rules live in its own file (`~/.claude/agents/comment-sicko.md`); do not restate them. When the agent type is missing, as in Codex or in a Claude Code session that started before the file existed, start a general agent whose prompt tells it to read that file and follow its body, plus the scope. Done when the report file exists and has one JSON line per comment.
2. Audit the report against the code:
   - Reject a verdict outside the scope, a `keep` without a keep-list exception number and its proof, a `must-kill` whose reason misstates the code, and a `delete` of a comment that an exception protects. Read every `delete` whose reason calls the claim unproven, unverified, or not re-proven: when the claim is about hardware, firmware, a vendor, or a live session the agent could not reach, the agent's proof rule for exception 2 accepts the commit that recorded it, so check that commit and the upstream source, and make it `keep` unless they refute it. A contract another repository relies on or a safety warning marked `delete` becomes `must-kill`.
   - For a thin `keep` or `must-kill` on an `IMPORTANT` or `do not remove` comment, run the agent's hunt yourself: the surrounding code, `git log -S`, `git blame`, and the upstream source the comment names. A refuted `keep`, or one with no proof the agent's exception-2 proof rule accepts, becomes `delete`.
   - Check that the agent missed no scoped lint or type suppression.
   - On a rejected report, rerun the agent once with the failure named. A second rejected report stops the skill: report it as open.
   Done when every line has an accepted verdict.
3. Apply `delete` and `move-to-docs`: remove each comment, and for `move-to-docs` write its facts into the named doc section in the same commit. Rewrite any doc that points at a removed comment in the same commit.
4. Fix a trivial `must-kill` directly: delete a dead path, drop a parameter, use the real interface, rename. When any fix needs a new shape, load the codebase-design skill once for the accepted set and its surrounding code, write the sketch into the report as an open item, leave that fix unimplemented, keep its comment until that refactor lands and list it with the sketch, and continue with step 5 for the other fixes.
5. Implement the smallest root-cause fix inside the scope, one commit per fix, and remove every workaround the comments named. When the root cause lies outside the scope, land the smallest in-scope fix and report the rest open. Add no guard that only hides the symptom. A fix that changes runtime behaviour beyond what the repository's checks prove goes to the report as open, with its blocker.
6. A constraint comment about our own code (`do not remove`, `do not change wording`, `talk to X before changing`, a contract another repository or program relies on, a safety warning): offer the cheapest in-scope encoding, a type, an assertion, a test, or a lint rule, and wait for the caller's approval; an unattended run needs approval given beforehand. With approval, encode it and then delete the comment. Without it, keep the comment and report the constraint as open and unenforced.
7. Run the repository's gate on the changed files and fix its failures.
8. Report: deletions, keeps by exception, moves to docs with their doc section, restored comments, reruns, the codebase-design sketch, fixes made, encoding offers and encodings, constraint comments kept as unenforced, and other open work.
