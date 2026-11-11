# devbox for Omer's own user

devbox is Omer's main dev machine. He and his agents work there as `omer`, reached with `ssh omer@devbox` (Tailscale SSH) from nixos-desktop or nixos-rog. Root work logs in as `ssh root@devbox`; this host has no `admin`. `omer` is not in the `docker` group, and its `sudo` asks for a password (Sudo, below).

## Where each tool comes from

Add a tool or setting to the layer that owns it, never by hand on the host.

| Layer | Holds | Kept current by |
|---|---|---|
| nixos-config (`machines/devbox/`, `home-manager/`, `agents/`) | The system, `omer`'s shell, editors, agent CLIs, their config and skills, and user units | the deploy timer, and the update workflow that moves inputs and apps |
| Each app's own file | Settings an app writes itself: `~/.grok/config.toml` above nixos-config's Grok defaults, Amp's, OpenCode's and OpenChamber's settings | the app; nothing copies them, so a reinstall starts them from nixos-config's defaults or the app's |
| Infisical `personal-secrets` `/harness/shell` | Omer's API keys; no shell exports them, so a command that needs one runs under `infisical run` with the Infisical Agent's token (Accounts and logins) | Omer, in Infisical |

## Shell and disk

- A project brings its own runtimes (Node, Bun, Go and the rest) through its devenv or mise config. Two global ones are on PATH for the agents' own tools: Node from nixos-config `home-manager/modules/agent-skills/default.nix` and Python 3 from `pkgs/agent-python.nix`, so a project that needs another version still pins its own.
- `omer`'s PATH has no `/usr/sbin`, so call `/usr/sbin/<tool>` (`swapon`, `sysctl`) or read `/proc` (`/proc/swaps`).
- `docker` as `omer` talks to `omer`'s rootless Docker (`docker.service`); the box runs no system Docker daemon. Rootless Podman still holds cliproxy and containers made before rootless Docker existed (`podman ps -a`); nixos-config `nixosModules/rootless-containers.nix` points the docker CLI at Docker's socket through `DOCKER_HOST`.
- `/tmp` deletes files nobody touched for 7 days (`systemd-tmpfiles`, `q /tmp ... 7d`). Put build output and anything that must last under `~/`, and worktrees under `~/Desktop/workspace/worktrees/` (the worktrees skill).
- The box has no `heavy` command; nixos-config installs it (`home-manager/modules/heavy.nix`) on nixos-desktop and nixos-rog only, so `codex-ask` runs Codex there without a cap of its own. Run a heavy suite, such as Gradle `:app:test`, the scraper's all-local suites or `pytest -n`, one at a time.
- The locale is `en_US.UTF-8`, whose `sort` orders case ties differently from `LC_ALL=C sort -f`. Merge into a list kept with `LC_ALL=C sort -f` using that same command.

## Services under `omer`

nixos-config `machines/devbox/home.nix` installs these user units.
- `infisical-agent.service` runs the Infisical Agent as the `omer-machines` identity. It keeps an access token in `$XDG_RUNTIME_DIR/infisical-agent/token` and writes `openrouter-guardrail.env`, which `openrouter-free-guardrail.service` reads, next to it (nixos-config `docs/devbox.md`, Agent runtime).

- `cursor-worker.service` is the Cursor Cloud Agent worker `devbox` (pick it at cursor.com/agents, or put `worker=devbox` in a Linear issue). `amp-runner.service` is the Amp runner `devbox` for `~/Desktop/workspace` and every Git checkout up to two levels under it, and a new clone shows up in Amp's picker at once. Start a runner thread in a served checkout, by picking the repository or passing `--runner-dir <checkout path>` to `amp --executor runner:devbox`, because a thread started in `~/Desktop/workspace` itself has no Changes tab. `amp-orb-provider.service` is Omer's personal Amp orb provider `devbox`, the default orb for his new threads; each orb is a rootless Docker container `amp-<thread id>` (nixos-config `docs/devbox.md`, Agent runtime).
- `openchamber.service` listens on 127.0.0.1:3000 and starts OpenCode itself on a random loopback port, so its Restart OpenCode and update buttons work. Omer opens it at `https://openchamber.risoluto.dev` from the tailnet.
- `cliproxy.service` runs CLIProxyAPI on rootless Podman, API on 127.0.0.1:8317, shared on the tailnet as `https://cliproxy.risoluto.dev`; details in nixos-config `docs/devbox.md` (CLIProxyAPI).
- `herdr-default.service` runs herdr's default session, where Omer's Claude agents live, and `claude-tools-limit-switch.timer` keeps them running (nixos-config `pkgs/claude-tools/README.md`). To start an agent again after it exited, run `claude-tools limit-switch resume NAME`, which restores its account, flags, and pane; a hand-written start loses the account or the flag. Before leaving agents running while Omer is away, read `unattended-agents.md` next to this file. To start, stop, read, or watch a named Claude agent in a herdr tab, read `~/.claude/reference/headless-clis/herdr.md` "Orchestrating agents" first (`claude-tools agent start|stop|watch`, `herdr agent prompt`).
- `herdr-web-ui.service` (`https://herdr.risoluto.dev`) serves herdr's web UI on the tailnet. Files pasted there land in `~/.local/state/herdr-web-ui/paste`, not in the pane's repository.
- `docker.service` is the rootless Docker daemon. nixos-config `nixosModules/rootless-containers.nix` keeps published host ports below the ephemeral range.

## Show Omer a file

Omer reads the box's files from nixos-desktop or nixos-rog through herdr, VS Code, or Dolphin ([agent-tools README](../../pkgs/agent-tools/README.md#read-remote-files)). For a markdown report, run `mdv PATH` from your herdr pane; it opens the rendered file in a new herdr tab and returns at once. For an HTML page, give him `xdg-open ~/remote/devbox<PATH>` to run on nixos-desktop or nixos-rog, because `ropen` shows HTML as source.

## Sudo

`sudo` as `omer` asks for a password, so `sudo -n` fails. The password is the Infisical record `DEVBOX_OMER_SUDO_PASSWORD` in project `statuslantern` (id in `$INFISICAL_STATUSLANTERN_PROJECT`), environment `prod`, path `/infra`. The box cannot read it: its CLI has no login, and the `omer-machines` token gets an empty answer for that path (checked 07-11-2026). So run the read on nixos-desktop or nixos-rog, where the CLI has Omer's login, and pipe it to `sudo -S` on the box so the value stays on stdin. From those hosts, for one-off root work:

```bash
infisical secrets get DEVBOX_OMER_SUDO_PASSWORD --plain --silent \
  --projectId "$INFISICAL_STATUSLANTERN_PROJECT" --domain https://eu.infisical.com --env prod --path /infra |
  ssh omer@devbox "sudo -S -p '' <command>"
```

- The pipe takes the command's stdin. For a command that reads stdin, or for several commands, run `sudo -S -p '' sh -c '<commands>'` with the input in a file.
- End the root work with `sudo -k`, because sudo caches the login for some minutes.
- Root follows the approval rules in `~/.claude/shared/core.md`. Host state that must last goes into nixos-config (`machines/devbox/`), which the box's deploy timer applies.
- As `omer`, `journalctl` for a system unit prints only `-- No entries --` and exits 0, so a count through `grep -c` reads 0. Read the system journal through the pipe above.
- The same password logs omer in to devbox's desktop over RDP. Before you ask Omer to open the `devbox` profile in Remmina on a workstation, store the password in that profile's keyring entry from that workstation, so Remmina logs in without asking. `tr -d '\n'` drops the newline that `--plain` adds, which devbox would refuse as part of the password:

  ```bash
  infisical secrets get DEVBOX_OMER_SUDO_PASSWORD --plain --silent \
    --projectId "$INFISICAL_STATUSLANTERN_PROJECT" --domain https://eu.infisical.com --env prod --path /infra |
    tr -d '\n' |
    secret-tool store --label='Remmina: devbox - password' xdg:schema org.remmina.Password \
      filename ~/.local/share/remmina/group_rdp_devbox_devbox.remmina key password
  ```
- To change the password, change `omer-password-hash` in nixos-config `secrets/devbox.yaml` (nixos-config `docs/devbox.md`, "Network and secrets") and update the Infisical record in the same change.

## Other hosts

The box carries `tag:infra-agent`, and the tailnet policy decides what it reaches.

- Agents cannot open a shell on nixos-desktop or nixos-rog; ask Omer instead. From this box the NixOS hosts' names do not resolve (`ssh nixos-desktop` prints `Could not resolve hostname`, checked 22-10-2026). Omer's browser there is reachable over CDP once he runs `browser-lend on` (Browsers, below).
- The six Status Lantern hosts (staging-1, prod-backend-1, prod-scraper-1, observability-1, ci-1, spare-1) take root SSH over the Status Lantern tailnet by their tailnet address and the repository's pinned host key (StatusLantern/statuslantern `docs/hosts.md`, Reach a host). Production deploys run through that repository's release; `devenv machines deploy` on a prod host by hand needs a founder's yes (`docs/hosts.md`, Deploy a host).
- A `!` command that Omer types in an agent session here runs on devbox with your own reach, so it adds nothing you could not run. Run every command yourself that this box reaches or that Sudo above covers. A step that needs Omer's machine or login, such as `browser-lend on`, names the machine first: "In a terminal on nixos-desktop, run ...".
- The SigNoz API (`signoz.statuslantern.com` on observability-1) answers this box on TCP 443, so the SigNoz MCP server works here. When it times out at session start, `/mcp` reconnects it.

## Browsers

Agents drive browsers with agent-browser; the agent-browser skill says which browser to use and how.

- The box browser holds Omer's logins: Chromium on the VNC display `:20`, DevTools on `127.0.0.1:9344`, profile in `~/.local/share/box-browser/profile`. Agents drive it with `box-browser`, and Omer signs in from his PC with `box-view devbox`. nixos-config `nixosModules/box-browser.nix` runs the display and the browser as user units.
- Omer's lent Brave (`browser-lend on` on his PC, `brave-browser --on <machine>` here) is for copying a passkey-only site's cookies into the box browser.
- A public page needs no lent browser: `agent-browser --session <name> open <url>` starts a throwaway headless Chrome.

## Accounts and logins

- `claude-tools accounts names` lists the Claude Code accounts, each with its own `CLAUDE_CONFIG_DIR` (`claude-tools accounts dir NAME`) and its own login; a credentials file is never copied between machines. Omer runs Claude as `clauded`, the zshrc alias for `claude --dangerously-skip-permissions`. Start or resume an agent for him with that flag; a script or `herdr agent start` passes it itself, because the alias exists only in interactive shells.
- Sessions that `claude daemon` starts show "Auto-update channel: disabled (set by env: DISABLE_UPDATES)" and the full model ID in /config. The daemon sets that variable, so neither is config drift.
- The AWS profile `statuslantern` (`us-east-1`, the Status Lantern account) needs no login. It trades the host certificate in `~/.aws/rolesanywhere/` for 1-hour AdministratorAccess credentials of the IAM role `devbox-agent` through IAM Roles Anywhere (Status Lantern `docs/aws.md`, Access), and the Status Lantern repository's `aws-mcp` MCP server signs with it. The certificate expires 29-10-2027; nixos-config `docs/devbox.md#aws-certificate` has the renewal steps.
- The Infisical CLI on the box has no login of its own (`~/.infisical` holds only `update-check.json`, checked 07-11-2026). A command authenticates with the token that `infisical-agent.service` keeps for the `omer-machines` identity: `INFISICAL_TOKEN=$(<"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/infisical-agent/token") infisical run --domain https://eu.infisical.com --projectId <project-id> --env secrets --path /harness/<folder> -- <command>`. That identity reads `/harness/**` in `personal-secrets` and statuslantern `dev`, so every `omer` process can reach those, until Status Lantern's roadmap entry 16a deletes the statuslantern records.
- Enes (`<enes-email>`) is a co-admin on purpose (Omer, 18-10-2026), with root through `/root/.ssh/authorized_keys` and the tailnet `group:admins` SSH rule, and an AWS `Admins` user.
- git pushes over the SSH key `~/.ssh/id_ed25519`. gh is logged in as OmerFarukOruc with the fine-grained token "statuslantern-factory-devbox": owner StatusLantern, repository `statuslantern` only, Pull requests read and write, Contents read and write, Actions read, Commit statuses and Metadata read, expiring 2027-02-07 (made 2026-11-10). So `gh` reaches no other repository. Renew or widen it yourself: open github.com/settings/personal-access-tokens in the nixos-desktop box browser, which is signed in as OmerFarukOruc (devbox's box browser is signed in as `statuslantern-tailscale`, which is not in the org), and write the new token into `~/.config/gh/hosts.yml` (mode 600) through stdin, because `gh auth login --with-token` hangs in gh 2.103.3 on devbox in its keyring lookup. Do not approve a GitHub CLI device code for devbox: OmerFarukOruc's GitHub CLI grant already includes `admin:org` and `delete_repo`, and a device token gets the whole grant. Codex, Grok CLI, amp, Cursor Agent, and linctl are logged in too.
- OpenCode holds API keys for OpenCode, OpenRouter, DeepSeek, Exa, Firecrawl, Parallel, Tavily, and TinyFish. Omer signs in to OpenAI, xAI, and Cursor himself in OpenChamber. A ChatGPT sign-in calls back to `127.0.0.1:<port>` on the machine with the browser, so from elsewhere use Codex device code, or run the callback URL with `curl` on the box while OpenChamber waits.
- Risoluto's domains (`risolu.to`, `risoluto.dev`) live in the Cloudflare account `risoluto`, not Omer's primary account. The token `STATUSLANTERN_CLOUDFLARE_DNS_API_TOKEN` failed from this box on 14-10-2026, likely a client address allowlist, so test it with a read call before planning a DNS write here.
