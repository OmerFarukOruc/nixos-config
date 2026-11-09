# Skill sources

Two kinds of skill come from other projects.

## Whole-skill copies

`home-manager/modules/agent-skills/default.nix` names each copy's flake input and the folder it takes. `flake.lock` holds the commit, and the `update` workflow moves it: to the branch head, or for gh-stack, which follows release tags, to the newest `v` tag. A copy with local edits has `<skill>.patch` in `home-manager/modules/agent-skills/patches/`; the `patches` check in `ci/patches.nix` applies every patch, so an upstream change that breaks one stops that input's move. Claude Code gets impeccable, diagram-design and eli5 as plugins (`agents/claude/settings.json`), and the copy reaches the other agents. avoid-ai-writing, grill-for-unknowns and untangle-codebase ship plugins too, but Claude Code gets their copies, because Claude Code 2.1.319 reads `skillOverrides` for a plugin skill only when the plugin sets `followsSyncedSkillState` or the account syncs its skill state; a `claude -p` session on 2026-11-08 still listed `avoid-ai-writing:avoid-ai-writing` to the model with both the plain and the plugin key set to `user-invocable-only`. After a Claude Code update, check again with `grep -ao 'function RYt(e){.\{0,200\}' "$(dirname "$(readlink -f "$(command -v claude)")")/.claude-wrapped"` (the minified name can change) and that `claude -p` listing. A copy that only Omer starts carries `agents/openai.yaml` with `allow_implicit_invocation: false`, which Codex reads, from its patch or, for avoid-ai-writing, from upstream. For such a copy the module adds `disable-model-invocation: true` to the `SKILL.md` frontmatter when upstream lacks it, which Claude Code and Antigravity read. A copy keeps only the files under its folder, so a license file at the upstream repository's root stays out. archify, herdr and impeccable are Apache-2.0, and every other copy is MIT (`gh api repos/<owner>/<repo> --jq .license.spdx_id`, 2026-11-09).

What each patch keeps, and why:

- ce-optimize: `agents/openai.yaml`; experiment worktrees go to `~/Desktop/workspace/worktrees/<repo>/`, the folder every worktree uses, and the cleanup removes only its own `optimize-*` folders; `references/measurement.md` 1.3 compares the first baseline sample with known durations in every mode; `references/optimize-spec-schema.yaml` names the `codex_security` value `workspace-write`, because codex-cli 0.167.0 has no `--full-auto` flag.
- clonedeps: the text names OpenCode, Claude Code and Codex, maps `@explorer` to each agent's explore agent, and tells the agent to search the clone with `rg <pattern> <clone path>`, because plain `rg` skips the git-ignored folder.
- codebase-design: `DEEPENING.md` tests every dependency category against the real dependency, and seam discipline counts only production adapters; an implementation is a thin wrapper over a vendor SDK, not an in-memory fake.
- diagnosing-bugs: `agents/openai.yaml`; read the glossary and ADRs first unless the user asks for an empirical local trial; search third-party trackers as `~/.claude/reference/tool-gotchas.md` says; Phase 5 starts from the existing tests and `~/.claude/shared/testing-discipline.md`.
- domain-modeling: skip glossary writes when the session is read-only or forbids Git or Linear changes.
- gh-stack: `agents/openai.yaml`; the description adds the trigger "when starting a branch from another unmerged branch".
- grill-for-unknowns, improve, research, stop-slop, untangle-codebase: only `agents/openai.yaml`.
- grilling: the body is ours: one question at a time, evidence before questions, decisions the agent owns, and a completion rule.
- handoff: state each blocker as a checkable condition and repository state as a command; point to a section or a search pattern in a document.
- herdr: a two-line note sends agents on devbox to `claude-tools agent start`.
- implement-spec: implementers follow the Testing rules in `~/.claude/shared/core.md` and `testing-discipline.md` instead of the `tdd` skill, and the final review is one `code-reviewer` agent.
- improve-codebase-architecture: the report goes to `/tmp/agents/architecture-<session8>/` and comes back as a link; a report-only request ends with the report.
- security-audit: a pointer to our harness in `agents/skills/security-audit-harness`.
- standards-spec-review: upstream's `code-review`, renamed because Claude Code ships a built-in `/code-review`; it runs its two reviews in-process in order when the user asks for that order.

## Skills that borrow ideas

These are our own text in this folder. Each row names the upstream file and the commit it was compared with last. No job watches them: to compare again, read the upstream diff from that commit and update the row.

| Skill | Upstream (owner/repo:path) | Commit read | What we took |
| --- | --- | --- | --- |
| crystal-plan | tobihagemann/turbo:claude/skills/draft-plan | d56f17f0ba88ead3a4a77fcdc884f80cd3d10d2f | List every path that references a deleted, renamed, or re-signed symbol; a proof drives an input the old code handles wrongly and never asserts through a test double |
| crystal-plan | tobihagemann/turbo:claude/skills/create-test-plan | d56f17f0ba88ead3a4a77fcdc884f80cd3d10d2f | A control run that differs only in the behavior under test |
| crystal-plan | humanlayer/humanlayer:.claude/commands/implement_plan.md | 77c7fe99ee2b5016f897437ef70c9726efc86092 | The Expected and Found shape of the executor's stop report (upstream deleted the file later) |
| crystal-plan | github/spec-kit:templates/commands/analyze.md | 7370e592f3cd9c06e5b698983957e227c75b30e2 | Coverage checked both ways, and vague words as a failed check |
| crystal-plan | bmad-code-org/BMAD-METHOD:skills/bmad-build/step-02-plan.md | 61e01f82644c4bb533750cfa0d6d61ab61d2cc9b | Re-check a claim with `git diff --stat <commit> -- <path>` before relying on it |
| crystal-plan | obra/superpowers:skills/writing-plans/SKILL.md | 2ce8aa15d05bd57213e6f746f953aafb7ded7a8b | Review Focus: the inputs a requirement implies but no test exercises |
| plan-review | tobihagemann/turbo:claude/skills/review-plan | 4b9f4cf74321a7ac4dddfe9298f8472bea74b9dc | Structure and scope checks |
| plan-review | tobihagemann/turbo:claude/skills/evaluate-findings | 4b9f4cf74321a7ac4dddfe9298f8472bea74b9dc | Verify each finding against the code; added machinery and reversed decisions go to the owner |
| plan-review | EveryInc/compound-engineering-plugin:skills/ce-doc-review | 67035e931c5cb26e80f198a7019a4502a9788273 | Finding format, confidence levels, admit by consequence, single-reviewer rule, earlier-round rules, assumption checks |
| writing-for-agents | mattpocock/skills:skills/productivity/writing-for-agents | 321658273cb1d20b76026717d027d505790106d4 | The whole skill: context pointers, the two loads, the information hierarchy, completion criteria, leading words, pruning |
| writing-for-agents | anthropics/skills:skills/skill-creator | b9e19e6f44773509fbdd7001d77ff41a49a486c1 | Reasons over emphasis, baseline runs, reading transcripts, generalizing fixes, description tests with near misses, keeping the name |
| writing-for-agents | openai/skills:skills/.system/skill-creator | 4ab6e0fd99c6667163bc34173e3ed3a3fed75ebc | Freedom matched to fragility, references one level deep, no auxiliary files, scripts and assets, Codex metadata |
| writing-for-agents | https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices | fetched 2026-10-08 | Descriptions in the third person, references one level deep, tables of contents, scripts run or read, testing on the weakest model, frontmatter limits |
| writing-for-agents | https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview | fetched 2026-10-08 | The three loading levels and what each costs |
| retro | mattpocock/skills:skills/engineering/retro | a7d038f6bf7f01b516408e95e2fb56e0b338fa6f | The categories and the implementation-versus-review reference; the verify, refute, and apply steps, the session digest, and the escapes, containment, orchestration, and outputs categories are local |
| test-audit | openclaw/openclaw:.agents/skills/test-audit (SKILL.md, CAMPAIGN.md, references/audit.md) and docs/help/testing/writing-tests.md | 70bfdc2b58e42f02af5bdc4d345875a9e6ad3928 | The campaign order of work and the junk and retention rules; `agents/reference/test-audit-openclaw.md` records each rule as adopted, adapted or rejected |
| agent-browser | vercel-labs/agent-browser:skills/agent-browser/SKILL.md | 021d9255e543d2f1ab66b87f338d85c3d7a910be | The discovery stub that loads `agent-browser skills get core`; the description and the browser, session and sign-in sections are ours |
| kvkk-compliance | https://www.kvkk.gov.tr/Icerik/8547/uretken-yapay-zeka-ve-kisisel-verilerin-korunmasi-rehberi-15-soruda | fetched 2026-10-27 | AI features: transfer abroad, transparency, automated results, prompt injection |
| kvkk-compliance | https://www.kvkk.gov.tr/Icerik/8142/Kisisel-Verilerin-Yurt-Disina-Aktarilmasi-Rehberi | fetched 2026-10-27 | Standard contract filing and the limits of occasional transfers |
| kvkk-compliance | https://www.kvkk.gov.tr/SharedFolderServer/CMSFiles/fb193dbb-b159-4221-8a7b-3addc083d33f.pdf | fetched 2026-10-27 | Cookie consent categories and the consent panel |
| oracle | steipete/oracle:skills/oracle/SKILL.md and skills/oracle-advisor/SKILL.md, plus LICENSE | b4017d263c73b851ecd71405a888a07331928719 | The brief layout, the smallest file set, the dry-run preview, reattaching instead of sending a prompt again, and accepting an answer only with model and effort evidence (MIT) |
| no-comments | cursor/plugins:pstack/skills/no-comments/SKILL.md, plus pstack/LICENSE | ce649c03ac3b75b6ae80cbd15b7e2c536caedb5a | The steps (MIT); `/how` and `/why` became the git and upstream hunt, `/architect` became the codebase-design skill, move-to-docs is ours, and the description and the default scope (every tracked file) make it a sweep |
| no-comments (agent) | cursor/plugins:pstack/agents/comment-sicko.md (copied to agents/claude/agents/) | ce649c03ac3b75b6ae80cbd15b7e2c536caedb5a | The keep-list and the hunt (MIT); the JSON Lines report, the firmware clause, and the move-to-docs verdict are ours; the comment definition moved out of Scope into its own section; code-reviewer reads that section, the keep-list, the hunt, and the verdicts |
| worktrees | JimLiu/baocut:AGENTS.md | e2864776f8bf97617af75f5b94ab3dbdd007634e | The rule that no worktree is left behind: remove each worktree and its branch at task end, commit and tag unmerged work as `archive/<name>` first, the session that starts subagents removes their worktrees, and a kept worktree is named with its reason |
| worktrees | max-sixty/worktrunk:docs/src/content/docs | b49ca7eea9b03145791a5b94eccaf9c59412ed37 | The `wt switch --create`, `wt remove --reap`, and `wt step prune` commands and the hook types, for the installed wt 0.80.0 |
| wayfinder | mattpocock/skills:skills/engineering/wayfinder | 4ae2317ddb22b046e26455e4f9c9b3aaaf62212d | The ideas only: decision tickets, fog, frontier, the map as an index; the Linear procedure is local |
| openai-image-gen | openai/skills:skills/.system/imagegen/SKILL.md | 49f948faa9258a0c61caceaf225e179651397431 (head on 2026-11-08, unchanged since the last comparison) | Input roles, prompt structure, focused iteration, inspection, and delivery into the consuming project; adapted for the OAuth CLI |
| openai-image-gen | openai/skills:skills/.system/imagegen/references/prompting.md | 49f948faa9258a0c61caceaf225e179651397431 | Specificity, layout, verbatim text, and edit preservation |
| openai-image-gen | https://developers.openai.com/api/docs/guides/image-prompting (GPT Image 2.6 prompting guide) | fetched 2026-11-08 | Flare and Sunburst choice, model parameters (quality, background, size rules), prompting fundamentals, edit, transparent-asset and iteration patterns |
| openai-image-gen | https://openai.com/index/introducing-images-2-6 | fetched 2026-11-08 (post dated 2026-11-04) | Model positioning (Flare speed, Sunburst detail and edit consistency), complexity and API-feature scope |
| openai-image-gen | https://developers.openai.com/api/docs/guides/image-generation | fetched 2026-11-08 | Size and area limits, complexity levels, SVG and GIF fields (documented as unavailable on this route) |
