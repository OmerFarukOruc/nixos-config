# Current bindings

Tool and model bindings for every campaign role. Verified 16-08-2026 and 17-08-2026, except where marked. The Codex model `gpt-6.1-sol` in Council, Writer, and the oracle fallback replaced `gpt-5.6-sol` on 03-11-2026: on codex-cli 0.166.0, `codex debug models` lists it with the medium, xhigh, and max efforts used below, and a read-only `codex exec -m gpt-6.1-sol` answered at xhigh and at max; no Writer or Council run has used it yet. When a binding changes, edit this file only; the route references stay untouched.

## Sessions

| Role | Model |
| --- | --- |
| create session | Claude Fable 5, high or xhigh effort |
| orchestrate session | Claude Opus 5, 1M context, high effort |

Set the session model by hand with `/model`. A skill cannot set it.

## Internal deep review

`/thermo-nuclear-code-quality-review ultracode`, invoked with the Skill tool.

## Council

Codex, GPT 6.1 sol at xhigh, read-only, with web search, started detached:

    codex-ask --model gpt-6.1-sol --effort xhigh --search plain <repo> <brief-file> <out-dir>

Run the `wait-exit` command it prints, again after each exit 124, then read `<out-dir>/answer.md`. `<out-dir>/codex.log` is the full tool transcript; never parse it for the answer.

Grok, 4.7 at xhigh, read-only:

    grok --no-auto-update --prompt-file <brief-file> -m grok-4.7 \
      --reasoning-effort xhigh --tools read_file,list_dir,grep,todo_write,web_search,web_fetch

The `--tools` list leaves Grok no shell, write, edit, or subagent tool, so it cannot change the repo and cannot stall on an approval prompt; `--allow` rules do neither. Give it anything it would otherwise run, such as a diff, as a file. The evidence is in `~/.claude/reference/headless-clis/operational-notes.md`, Grok CLI.

## Writer

Codex, GPT 6.1 sol at medium, workspace-write. Pass the effort explicitly, because `~/.codex/config.toml` changes across sessions and `gpt-6.1-sol` defaults to `low`. Start it under `heavy`, so a build or test suite it runs gets a capped scope of its own instead of the caller's; on devbox, which has no `heavy`, drop that word:

    heavy codex exec --sandbox workspace-write -m gpt-6.1-sol \
      -c model_reasoning_effort="medium" -C <worktree> \
      --add-dir <repo>/.git -o <last-message-file> "<prompt>"

- The session id prints in the stdout header as `session id: <uuid>`.
- `--add-dir <repo>/.git` is required. A linked worktree shares the main repo's `.git`, and the sandbox blocks the writer's commit without it.
- Resume with a verdict, from the worktree as cwd:

      heavy codex exec resume <session-id> -m gpt-6.1-sol \
        -c model_reasoning_effort="medium" -o <last-message-file> "<verdict>"

## Spec gate

The Spec gate runs the oracle skill's steps 1 to 7 (`skills/oracle/SKILL.md`) with the spec-gate brief as `brief.md` and a slug made from the campaign name. The campaign request is Omer's request for this consult. When the skill's host check fails, as on devbox, use the fallback below.

Fallback when oracle fails, waited for the same way as the Council call:

    codex-ask --model gpt-6.1-sol --effort max plain <repo> <brief-file> <out-dir>
