---
name: model-consult
description: "Consults another model's CLI (claude, grok, codex, agy/Gemini) from inside a task for a second opinion, heavy reasoning, reverse engineering, decoding, or math. Use when Omer asks to \"ask grok\", \"ask kimi\", \"ask claude\", \"ask codex\", \"consult another model\", \"get a second opinion\", \"cross-check with another model\", or names a model such as fable, opus, astra, sol, neon or kimi; when a problem would profit from an outside model's strength even if he names none; and when a consult call errored or was refused, to decide the retry and the fallback lane."
---

# Model consult

Shell out to another model's CLI for a second opinion, heavy reasoning, reverse engineering, decoding, or math the current model should not carry alone. Four lanes answer on this machine; each is an independent single-turn command, they run in parallel, and they share nothing. pi (Kimi) is installed but has no provider logged in, so it is not a lane: check `pi auth check --provider opencode-go` and `notes.md` before routing there.

Per-CLI depth — sandboxing, session ids, output formats, prompt files, auth recovery — lives in `~/.claude/reference/headless-clis/operational-notes.md`. Read the lane's section there before composing anything beyond the plain command in the table; this skill is the router, not the cache.

## Lanes

| Lane | Plain command | Models | Reach for |
| --- | --- | --- | --- |
| Claude | `claude -p --model claude-fable-5-2 "<brief>"` | `claude-fable-5-2`, `claude-opus-5-5` | the hardest reverse engineering, decoding, algorithms, subtle bugs; premium quota |
| Grok | `grok -p "<brief>"` | `grok-4.7`, `grok-4.6` (default `grok-4.7-build-fast`) | quick sanity checks, reasoning, review-shaped consults |
| Codex | `codex-ask` | `gpt-6.2-astra`, `gpt-6.2-sol`, `gpt-6.1-terra` | deep reasoning, math, architecture review |
| Gemini (agy) | `agy --model gemini-4-neon-high -p "<brief>"` | `gemini-4-neon-{low,medium,high,xhigh}` | good all-round reasoning, cheap consultations, long-context analysis |

Lane notes:

- **Claude**: the two IDs are the pinned full names; the `fable` alias also resolves to Fable 5.2. A weekly usage cap applies, and a capped run prints the limit message with the reset time and exits 0 — check the reply text, not only the exit code. Record the cap in `notes.md` and route elsewhere until the reset.
- **Grok**: the default model is the build-fast variant; pass `-m grok-4.7` for the general model. `grok models` may print `not authenticated` while `-p` runs still work — trust a probe. A review-shaped consult can take `--agent code-reviewer`; plain runs need no agent.
- **Codex**: `codex-ask` wraps `codex exec`, backgrounds it, and prints the `wait-exit` invocation to use; the unwrapped form is `codex exec --skip-git-repo-check -s read-only -m gpt-6.2-astra "<brief>"`. Reasoning effort defaults to `low`; pass `-c model_reasoning_effort=high` (up to `ultra`) for a hard question. The token-usage footer in the output is normal.
- **Gemini (agy)**: put `--model` before `-p`, or agy reads the model flag as the prompt. Gate before routing — `timeout 20 agy models` must list models; a sign-in prompt or a timeout means the lane waits on Omer's interactive `agy` sign-in. Neon is the workhorse; carbon is new and unrated; argon is retired (operator decision 2026-11-28) even though the catalog still lists it; hydrogen only for trivial lookups. The catalog also mirrors `claude-opus-5-5-*`, `claude-sonnet-5-5-*` and `gemini-3.8-flash-*`, useful for a cross-family check without a second login.
- **Oracle** (ChatGPT Pro through the browser) is a lane Omer starts himself with `/oracle`; the skill of that name holds its procedure. It spends his ChatGPT Pro allowance, so never fire it on your own.

## The brief

The consulted model sees only what the command carries. Write it so a cold model can answer:

- one question per call, with the answer shape named ("ranked hypotheses with the evidence that would confirm each", "a patch plan", "a decision with its trade-offs");
- the artifact inline, or an absolute path — claude, codex, agy and grok read files in the working directory, and grok headless reads only inside its `--cwd`;
- the piece, not the story: give the mechanism, the data and the constraints, and leave the task narrative out — a cold model cannot use it, and the answer gets sharper without it.

## Running

- Set a generous timeout, 120–300 s; hard questions take minutes. Never retry a call that is still running.
- A consult that must not touch the repo runs sandboxed: codex `-s read-only`, grok `--sandbox read-only`. The sandbox flags live in operational-notes.md.

## When a call errors or refuses

1. Read the message. Quota, auth and sign-in failures name themselves — record the state in `notes.md`, switch lanes, and move on.
2. A refusal on a legitimate technical question is usually the phrasing: rewrite the question as a cleaner, more self-contained technical question and retry once. Single-turn commands always start a fresh session, so the retry is clean.
3. After two failed rewrites, take the question to another lane. Never loop the same phrasing.

## Parallel consultation

The lanes are independent CLIs; consult several in one tool-call block, each with its own timeout:

- **Cross-check**: the same question to two families (fable + astra, neon + grok); disagreeing answers on a hard decode are the signal to dig, agreement a strong quality signal.
- **Divide and conquer**: each lane gets a self-contained piece — one runs the crypto puzzle, another catalogs the strings, a third reviews the architecture — and you merge the answers.
- **Fallback racing**: when one lane is flaky, fire a second alongside it and take the better answer.

## notes.md

Append one line per event worth remembering — a quota cap with its reset, an auth state, a lane notably strong or weak at something, a model ID that stopped resolving — and read the file before routing. Format: `YYYY-MM-DD lane note`.
