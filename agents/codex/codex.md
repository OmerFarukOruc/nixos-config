## Codex

- Before writing for Omer, read `~/.claude/rules/voice.md` unless already read in this session. That file owns the detailed writing policy. Lead with the outcome and use clear, concise prose.
- Use collaboration tools to delegate independent work when parallel execution could save time or improve quality. This applies to the root agent and subagents. Give each subagent a concrete scope and require evidence with its result. The coordinating agent verifies the results and writes the user-facing report.
- Pass `fork_turns="none"` explicitly on every `spawn_agent` call, including calls made by subagents. Give each agent a self-contained task message with the context it needs, because it starts without the parent conversation.
- When Omer asks for a dual review, or the diff is release-critical or security-critical, run independent Claude Opus and Grok xhigh passes. Keep their session ids.
- Run the affected tests once after the related edits, not between each one. After required checks pass, continue toward completion. Run additional checks only for a new change, a failure, or a specific unresolved concern. Choose a check that can resolve that concern.
- During a long-running gate, report the active stage, elapsed state, and next boundary. Claim completion only on explicit completion evidence.
- A prompt that invokes a named skill carries only task-specific configuration; the skill supplies its own workflow and checklist.
- On devbox, `cf` comes from nixos-config (`pkgs/cf.nix`). In a project with no Wrangler config, where `command -v cf` fails, say so and ask before using Wrangler instead.

## Cloudflare CLI - cf - v20260928

`cf` is Cloudflare's current CLI and covers the whole Cloudflare platform. Prefer it over Wrangler: create projects with `cf init`, develop with `cf dev`, deploy with `cf deploy`, and manage account resources with `cf <product> …` (for example `cf d1 list`).

Wrangler is only for projects that already use it – a `wrangler.jsonc`, `wrangler.json` or `wrangler.toml` file – or when the user asks for it. Keep using Wrangler in those projects unless asked to migrate, and use `cf migrate` in this case.

`cf` commands differ from Wrangler's; check `cf --help` or `cf cli search <what you want to do>` instead of guessing. If a `cf` command fails in a project that doesn't use Wrangler, don't fall back to Wrangler (including `npx wrangler`) without offering to report it.
