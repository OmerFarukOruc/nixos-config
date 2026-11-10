# Claude Code on this host

## Subagent model and effort

- `CLAUDE_CODE_SUBAGENT_MODEL` is a default. An agent-definition `model` field or a per-call `model` argument wins, unless `CLAUDE_CODE_SUBAGENT_MODEL_FORCE` is set, and a definition with `model: inherit` runs the session model. A Workflow `agent()` call also gets it when neither the call nor the agent definition sets a model, although the workflow-authoring skill says such a call inherits the session model. Inside a workflow run, `CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL`, when set to anything but `inherit`, replaces every other model choice, the per-call `model` included. Pass `model` per call when it matters.
- The built-in Explore and Plan agents have `model: "inherit"`. On the first-party API, Claude Code 2.1.322 caps Explore at Opus when the session runs Fable or Mythos, unless `CLAUDE_CODE_DISABLE_EXPLORE_INHERIT_CAP` is set; Plan has no cap. `grep -ao '.\{250\}if(i.CLAUDE_CODE_DISABLE_EXPLORE_INHERIT_CAP).\{120\}' "$(readlink -f "$(command -v claude)")"` shows the rule in the installed version.
- Agents inherit the session effort, which `effortLevel` in `settings.json` sets (per model under `modelSettings`), unless an agent definition's `effort` field or a per-call `effort` argument sets one. `CLAUDE_CODE_SUBAGENT_EFFORT` sets the effort of a subagent that has neither, so it never changes an agent whose definition sets `effort`, such as `code-reviewer`.
- `env-vars.md` does not list `CLAUDE_CODE_SUBAGENT_EFFORT` or `CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL`, but Claude Code 2.1.322 reads both: `grep -ac CLAUDE_CODE_SUBAGENT_EFFORT "$(readlink -f "$(command -v claude)")"` counts 8 matches, and the same for the workflow variable. Run that check again after an update before relying on either.
- Read the model column in `/workflows` or `/tasks` to confirm what an agent ran with.
- To write prompts for a newer model, read only that model's section of the bundled claude-api guide instead of loading the skill, because the file is about 340 KB: `awk -v m="Opus 5.5" '/^## /{p=index($0,"Migrating to") && index($0,m)>0} p' "$(ls -t /tmp/claude-*/bundled-skills/*/*/claude-api/shared/model-migration.md | head -1)"`, with `m` set to the model's name.

## Output and background limits

- When a `Write` or another tool call fails because the response hit the output-token limit, write the file as a skeleton, then append one section per `Edit`.
- Before reporting a background job as still running, confirm it is alive: `ps -p <pid>` for a Bash job, `ListAgents` for an agent, the run's `journal.jsonl` for a Workflow. Silence is not liveness.
- At most 6 agents run at once in a workflow and 6 subagents through the Agent tool, because `settings.json` sets `CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS` and `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`. The two caps count separately, so keep the total running at once at 6 or fewer. Keep both caps at 6, because an audit workflow that ran 9 agents at once on nixos-desktop used 17 GB RAM and 25.9 GB swap, and the kernel's OOM kill made systemd stop two Claude sessions. Give a workflow more items instead; the extra items queue. The Agent tool refuses a launch past its cap instead of queueing it, so wait for a running subagent to finish before you start the seventh.
- When a subagent returns a file path as its deliverable, run `test -s <path>` before you accept the result. A missing or empty file means the deliverable is missing, so ask the subagent for it with `SendMessage` before you rely on its summary, because a summary can name a file its agent never wrote.

## Skills directory

- Own skills in `~/.claude/skills/<name>` link into nixos-config `agents/skills/<name>`, so an edit there works at once; a new or removed folder needs a Home Manager switch. Upstream copies are read-only store paths: change one through its patch in `home-manager/modules/agent-skills/patches/` (nixos-config `agents/README.md`).

## Login

- Claude Code rotates the OAuth refresh token on use. Two processes or role homes that share one `.credentials.json` log each other out, so give each login its own file.

## Safeguard flags

- Opus 5.5 runs bio and cybersecurity classifiers. Finding vulnerabilities in source code is allowed; high-risk dual-use cybersecurity activity is not.
- `switchModelsOnFlag: false` in `settings.json` makes a flagged session pause instead of switching to an older model, so a reverse-engineering session never changes model unnoticed. Keep it false.

## Bash sandbox

- Leave the Bash sandbox at its default, off, so `settings.json` sets no `sandbox` key. When on, it left empty placeholder files in the working checkout (`.bashrc`, `.gitconfig`, `.mcp.json`, `.claude/settings.json`, and others) and an empty `.git/config.lock` that made every `.git/config` write fail, even outside the sandbox. Turning it back on brings them back.
