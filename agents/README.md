# agents

This folder holds the configuration of Omer's agent CLIs: Claude Code, Codex and the others. `home-manager/modules/agents.nix`, which `nixosModules/agents.nix` imports on nixos-desktop, nixos-rog and devbox, keeps a main checkout of this repository current on each of them and links each home to this folder in that checkout, so an edit works at once.

## Layout

| Path | Read through | Holds |
| --- | --- | --- |
| `shared/` | `~/.claude/shared` | `core.md`, the rules every agent follows, and the rule files it points to |
| `claude/CLAUDE.md` | `~/.claude/CLAUDE.md` | Claude Code's user instructions, which import `core.md` |
| `claude/rules/` | `~/.claude/rules` | Claude Code rule files |
| `reference/` | `~/.claude/reference` | reference pages the rules send agents to |
| `infisical.md` | `~/.claude/infisical.md` | the Infisical usage note |
| `skills/<name>/` | `~/.claude/skills`, `~/.agents/skills`, `~/.gemini/antigravity-cli/skills` | Omer's own skills; `skills/SOURCES.md` names what they borrow |
| `claude/hooks/` | `~/.claude/hooks` | Claude Code hooks: `bash-guard.py` with its modules, `guard-main-edit.py`, `bash-env.sh`, `stop-sound.sh` and its sounds |
| `claude/statusline.sh` | `~/.claude/statusline.sh` | the status line |
| `claude/agents/` | `~/.claude/agents` | the `code-reviewer` and `comment-sicko` agents |
| `claude/mods/paste-card/` | `CLAUDE_CODE_PLUGIN_DIRS` | the `paste-card` mod |
| `claude/settings.json` | `~/.claude/settings.json` | Claude Code's settings |
| `codex/codex.md` | `~/.codex/AGENTS.md` | the Codex-only rules |
| `codex/agents/` | `~/.codex/agents/<file>` | the Codex agent roles `default`, `worker`, `explorer` and `code_reviewer`, which reads `claude/agents/code-reviewer.md` |
| `grok/managed_config.toml` | `/etc/grok/managed_config.toml` | Grok's default settings |

Each path above `claude/settings.json`, and each file in `codex/agents/`, is a live link into the checkout or, for the mod, its path; a new file in `codex/agents/` gets its link at the next switch. `programs.claude-code.settings` merges `claude/settings.json` into `~/.claude/settings.json` at each switch with `mutableSettings`, so Claude Code and `herdr integration install claude` can still write to that file and keep their keys, such as each host's `autoMode.environment`. A declared key overwrites the live one, a declared list replaces the live list, and a key removed from `claude/settings.json` stays in the live file until someone deletes it there. Other hooks come from elsewhere:

- herdr writes its `SessionStart` hook.
- `programs.worktrunk.claudeCodeIntegration` (`home-manager/modules/agent-cli.nix`) adds the `WorktreeCreate` and `WorktreeRemove` hooks, which run `wt`, and activity hooks that set a marker for `wt list` in the repository's `.git/config` at each prompt, question, and stop. `agent-cli.nix` replaces its `WorktreeRemove` command with one that passes `--force`, so a discard at exit removes a worktree with uncommitted changes. `WorktreeCreate` runs `wt switch --create`, so it fails for a branch that already exists, and an `isolation: "worktree"` agent's worktree starts from the default branch, not from the parent session's commit.
- `home-manager/modules/claude-tools.nix` adds the `StopFailure` hook that `claude-tools rotate` reads.
- The impeccable plugin adds a `SessionStart` hook, a `PostToolUse` hook on `Edit|Write`, and a `Stop` hook, each running its `impeccable hook` script.

Enabled plugins and their marketplaces are settings keys. Claude Code fetches a plugin that user settings enable once a session starts, and loads it from the next session on. `autoUpdate` on a marketplace makes Claude Code update it and its plugins after a session starts; Anthropic's own marketplaces update without it.

An edit inside a `skills/<name>/` folder works at once, but a new folder gets its links only at the next Home Manager switch, because the module lists `skills/` when it evaluates. Skills copied whole from other projects come from flake inputs: `home-manager/modules/agent-skills/` applies each local patch from its `patches/` folder and links the result into the same three folders, and into `~/.codex/agents` for impeccable's Codex agents. A skill whose upstream ships a Claude Code plugin reaches Claude Code as that plugin and the other agents as the copy, unless only Omer starts it, which `skills/SOURCES.md` explains. `skills/SOURCES.md` lists both kinds and what each patch keeps. The module writes `home.file` entries instead of using `programs.claude-code.skills`, because that option fills only `~/.claude/skills`, the other two folders need the same names, and the own skills need links into the checkout.

Grok 1.0.77 reads `/etc/grok/managed_config.toml` as a layer below `~/.grok/config.toml`, so these defaults reach every host while a setting changed inside Grok wins on that host and stays there; `grok inspect --json` lists both files under `configSources`. `nixosModules/agents.nix` writes the file at each NixOS switch. Its keys leave out the ones Grok writes as state (`privacy`, the `marketplace` install flags, `cli.installer`) and the `rea` MCP server, which only nixos-rog installs by hand and which its own `config.toml` keeps. The Grok package already sets `GROK_DISABLE_AUTOUPDATER=1`, and the Amp package `AMP_SKIP_UPDATE_CHECK=1`, so neither config turns updates off.

`~/.codex/AGENTS.md` is a file that Home Manager builds from `shared/core.md` and `codex/codex.md`, so a change to either reaches Codex at the next switch, within the hour on every host, the PCs only on AC power (the repository's `AGENTS.md`). Home Manager's `programs.codex` would also build it, but with `home.preferXdgDirectories` on these hosts it moves `CODEX_HOME` to `~/.config/codex`. `programs.claude-code` has `context` and `rulesDir`, but `context` would write the link's store path as text and `rulesDir` links file by file, so a new rule file would wait for a switch; raw `home.file` entries avoid both.

Each entry sets `force`, because Home Manager backs up only a target that is not a symlink, and the links an earlier setup left there would otherwise stop the switch. Each switch also runs `agents-pull` before it ends, so the links never wait an hour for files the deployed commit added.

The commands these files name, such as `pr-land`, `wait-exit` and `sandbox-run`, come from `pkgs/agent-tools`, which the same module installs ([its README](../pkgs/agent-tools/README.md)).

Private values stay out of these files ([Checks](#checks)). The Infisical project IDs reach every zsh, interactive or not, through `.zshenv` as `$INFISICAL_PERSONAL_SECRETS_PROJECT` and `$INFISICAL_STATUSLANTERN_PROJECT` from the sops secret `agents-infisical-ids`.

## Edit loop

- Edit `agents/` in the main checkout (`~/Desktop/workspace/nixos-config`, the option `oruc.agents.checkout`), commit to `main` there, then run `git pull --rebase` and `git push origin main`. Every other path of this repository still needs a worktree. The pull unit below sets `git config agents.mainCheckoutEditPaths agents/` in the checkout, and Claude Code's edit guard allows the main checkout only for those paths.
- A main checkout needs `direnv allow` once, so the commit hooks find their config.
- Before you commit a change to `model` or `effort` in `claude/agents/`, start that agent once with no per-call `model` or `effort` and confirm the model it ran with `jq -r 'select(.type=="assistant") | .message.model' <transcript> | sort -u`, which prints one model name. The transcript is `~/.claude/projects/<project>/<session>/subagents/agent-<id>.jsonl`, under `subagents/workflows/<runId>/` for a Workflow agent, and `<id>` is the agent id the Agent tool returns. No check reads the frontmatter, and Claude Code 2.1.322 sends an unknown model name to the API, so the agent ends with `model_not_found` and the command prints `<synthetic>`.
- `agents-pull.timer` runs `agents-pull` every hour. It clones the checkout when the folder is missing and otherwise fetches `origin` and fast-forwards `main` to its upstream. The fetch rewrites GitHub's SSH URL to HTTPS for that one command, because the repository is public and the switch that also runs it has no `ssh` and no SSH agent; pushes keep SSH through the `pushInsteadOf` in `home-manager/modules/git.nix`. A failed run leaves a line that each new shell prints until a run succeeds (`home-manager/modules/scheduled-unit.nix`); `journalctl --user -t agents-pull` shows the run. An unreachable GitHub is not a failure.

## Checks

The pre-push gate (`ci/gate.sh`) checks every commit between `origin/main` and the pushed revision:

- `ci/private-scan.sh` runs on every push. It runs `gitleaks git` on those commits and refuses one whose message or added lines, binary files and merge results included, hold one of Omer's private values, such as an account email, an Infisical project ID or the tailnet name. This repository is public and keeps every pushed commit, so a value has to be gone from the commit itself, not only from a later one. The values come from the sops secret `agents-private-values` in `secrets/agents.yaml`, one per line, decrypted to `/run/secrets/agents-private-values` on nixos-desktop, nixos-rog and devbox; `AGENTS_PRIVATE_VALUES` names another file. The scan prints the commit and the file of a hit, never the value. Add a value with `sops secrets/agents.yaml` ([Secrets](../docs/architecture.md#secrets)).
- `ci/agents-checks.sh` runs when those commits touch `agents/`. It runs shellcheck on each `.sh` file and ruff on each `.py` file, and parses each `.json` and `.toml` file, as the pushed revision holds them.
- When every path those commits touch is under `agents/`, the gate skips the Nix checks, unless a `.nix` file names one of those paths or the commits add or remove a folder under `skills/` or a file in `codex/agents/`. `home-manager/modules/agents.nix` reads `shared/core.md` and `codex/codex.md` this way, so a change to either runs the Nix checks, and `home-manager/modules/agent-skills/` lists `skills/`, and `agents.nix` lists `codex/agents/`, when Home Manager evaluates.
