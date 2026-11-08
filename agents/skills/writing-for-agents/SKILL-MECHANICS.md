# Skill mechanics

The skill-specific branch of [`writing-for-agents`](SKILL.md): what changes when the document is a skill (frontmatter, the invocation choice, and router skills). Everything else about writing it is the universal reference in `SKILL.md`.

## Frontmatter

A skill's frontmatter holds `name` and `description`, plus `disable-model-invocation: true` when only a person should trigger it. These limits are hard; the vendors reject a skill that breaks them:

- `name`: at most 64 characters of lowercase letters, digits, and hyphens, equal to the folder name. Choose a name that says what the skill does; a vague one (`helper`, `utils`) is a pointer that never fires.
- `description`: at most 1024 characters, no XML tags. Put it in double quotes when it contains a colon followed by a space, or YAML reads it as a nested key.

The skill-creator validators' list of allowed fields is advisory lint: Anthropic's rejects `disable-model-invocation`, which Claude Code honours.

## Files

A skill folder holds only what the agent uses:

- `references/` for material the agent reads when a pointer sends it there;
- `scripts/` for code it runs;
- `assets/` for templates and files it copies into its output.

A README, changelog, setup guide, or notes on how the skill was made belong outside the folder, in the repository's own docs. Create only the folders you fill.

## Updating

Keep the `name` and the folder name: prompts, other skills, and people point at them. A rename is a migration: search for every pointer to the old name and change it in the same change.

## Portability

One skill folder serves Claude Code and Codex:

- Both read `name` and `description`. The person-only switch differs: Claude Code reads `disable-model-invocation: true`, and Codex reads `policy.allow_implicit_invocation: false` in `agents/openai.yaml`. A person-only skill sets both.
- `agents/openai.yaml` is Codex interface metadata (`display_name`, `short_description`, `default_prompt`) that restates the description. It is a cache: update it whenever the description changes.
- Prompts for subagents the skill starts go in `references/`; in Codex, `agents/` belongs to the harness.
- Name a skill without its invocation sign. Claude Code types `/name` and Codex types `$name`, so either sign is wrong in one of them.
- A step that needs subagents, a browser, or a vendor CLI says what to do when the caller lacks it.
- A script states the packages it needs and installs them locally, never globally.

## Invocation

Two choices, trading the two loads:

- A **model-invoked** skill keeps a `description`, so the agent can fire it autonomously, and other skills can reach it. You can still type its name: model-invocation always _includes_ user reach; a description only ever adds agent discovery, never removes the human's. The description is the skill's top-level context pointer, forced to stay loaded at all times: permanent context load in exchange for discoverability. A model-invoked skill whose content is all reference is also one home for shared reference: another skill can invoke it, so reference needed by several skills lives in one place. Mechanics: omit `disable-model-invocation`, and write a model-facing description carrying the trigger branches (the pointer-writing rules in `SKILL.md` apply in full).
- A **user-invoked** skill strips the description from the agent's reach: only the human typing its name can invoke it, and no other skill can. Zero context load, but it spends cognitive load: you are the index that must remember it exists. Mechanics: set `disable-model-invocation: true`; the `description` becomes human-facing: a one-line summary, trigger lists stripped.

Pick model-invocation only when the agent must reach the skill on its own, or another skill must. If it only ever fires by hand, make it user-invoked and pay no context load.

Shared reference that two user-invoked skills both need can live in neither: with no descriptions, neither can fire the other. Push it to a plain file outside the skill system: external reference any skill can point at.

## Splitting by invocation

The invocation cut of splitting (the sequence cut lives in `SKILL.md`): split off a model-invoked skill when you have a distinct leading word that should trigger it on its own (a trigger word you actually use in your prompts), or another skill must reach it. You pay context load for the new always-loaded description, so that independent reach has to be worth it.

## Router skills

When user-invoked skills multiply past what you can remember, that piled-up cognitive load is cured by a **router skill**: one user-invoked skill that names the others and when to reach for each, so the human has one skill to remember instead of many. It can only hint, never fire them: user-invoked skills have no description, so nothing but the human can reach them.
