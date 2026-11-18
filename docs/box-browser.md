# Agent browsers

Coding agents drive signed-in browsers with agent-browser through one command,
`box-browser` (`pkgs/agent-tools/bin/box-browser`), installed on nixos-desktop,
nixos-rog and devbox. It reaches two kinds of browser:

- The box browser: one Chromium on devbox that Omer signs in to once and that
  every agent session shares, each in its own tab. Agents use it by default,
  because it never waits for Omer.
- Omer's Brave Origin, on the PC he sits at, for an agent that runs on that
  PC. Brave asks him to click Allow for each new agent session, so agents use
  it only for what the box browser cannot do, such as a site that signs in
  only with a passkey. No agent on devbox reaches it.

A page that needs no login opens in a throwaway headless browser
(`agent-browser --session <name>`) instead. The agent-browser skill
(`agents/skills/agent-browser/SKILL.md`) tells agents which browser to pick.

- [The command](#the-command)
- [Box browser](#box-browser)
- [Omer's Brave](#omers-brave)
- [Login codes](#login-codes)
- [Security model](#security-model)
- [Check](#check)

## The command

```sh
box-browser [--session NAME] [--on HOST] COMMAND...                  # box browser
box-browser [--session NAME] --brave COMMAND...                      # Omer's Brave
box-browser [--on HOST] status                                       # box browser units and DevTools
```

COMMAND is an agent-browser command, such as `open <url>` or `snapshot -i`.
The session is `--session`, else `AGENT_BROWSER_SESSION`, else
`CLAUDE_CODE_SESSION_ID`, else `CODEX_THREAD_ID`; with none of them the
command exits 2. Each session keeps its own pinned tab
(`AGENT_BROWSER_PIN_TAB=1`).

Without `--brave`, the command drives this host's box browser when the host
runs `box-browser.service`, and devbox's over `ssh devbox` otherwise; `--on`
names another host. A file the box browser writes, such as a screenshot, stays
on devbox. With `--brave`, it drives this host's Brave Origin; it refuses
`--on`, and it fails on a host that runs the box browser. The first `--brave` call of a session waits up to 10 minutes for
Omer's Allow click.

The command runs the first `agent-browser` on `PATH`, which Home Manager
installs from llm-agents.nix (`home-manager/modules/agent-cli.nix`).

## Box browser

`features.boxBrowser` in a host's record in `machines/inventory.nix` turns it
on; devbox is the only host that sets it. `nixosModules/box-browser.nix` holds
the units and the policy, and `home-manager/modules/box-view.nix` the viewer.
The feature needs no secret and no tailnet policy change. A host that turns it
off keeps the signed-in profile in `~/.local/share/box-browser`; delete that
folder there.

- `box-display.service` (user unit) is Xvnc on display `:20`, listening on
  `127.0.0.1:5920` with no password (`-SecurityTypes None`) and the desktop name
  `box-browser`, which the viewer shows in its window title.
- `box-browser.service` (user unit) is nixpkgs Chromium on that display, with
  the profile in `~/.local/share/box-browser/profile` and DevTools on
  `127.0.0.1:9344`. Both units restart on failure, and a restart of the display
  restarts the browser. `users.users.<user>.linger` keeps them running without a
  login.
- `/etc/chromium/policies/managed/box-browser.json` turns Chromium's password
  manager off (`PasswordManagerEnabled`), so the profile saves no password
  ([Security model](#security-model)).
- `box-view` (command and menu entry "Box browser", on nixos-desktop and
  nixos-rog) opens the viewer on `127.0.0.1::5920`. For another host it runs
  `vncviewer -via <host>`, and TigerVNC's viewer opens the SSH tunnel itself
  with the command in `VNC_VIA_CMD`, which keeps `BatchMode` and
  `ExitOnForwardFailure`. A failure of the viewer or its tunnel also shows as a
  desktop notification, since the menu entry has no terminal.

To sign in, run `box-view`, or open Box browser from the menu, sign in to the
site in the Chromium window, then close the viewer. The session stays in
devbox's profile. With no argument the viewer opens devbox's display from a
PC, and the host's own display on a host with `features.boxBrowser`; `box-view
<host>` names another host. Agents sign in by themselves when a secret store
holds the password, as the agent-browser skill says, so Omer signs in only to
what no store holds.

## Omer's Brave

On nixos-desktop and nixos-rog, `box-browser --brave` drives the local Brave
Origin. Turn on `brave://inspect/#remote-debugging` once; Brave Origin then
writes its port and path to
`~/.config/BraveSoftware/Brave-Origin/DevToolsActivePort`, which the command
reads, because its `/json` answers 404.

## Login codes

The box browser holds no mail account. A site that sends a sign-in code by
email sends it to Omer's Gmail, where a filter forwards the code mails of each
named sender to a separate login-code mailbox. `login-code`
(`pkgs/agent-tools/bin/login-code`) reads that mailbox read-only over IMAP,
downloads only the sender's mails, and writes only the code, 4 to 12 letters,
digits or dashes, to a 0600 file, so no agent reads a mail. Take the time
before you request the code, so an older code does not count:

```sh
d=$(mktemp -d) && t=$(date +%s)
# request the code on the site, then:
INFISICAL_TOKEN=$(<"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/infisical-agent/token") \
  infisical run --projectId "$INFISICAL_PERSONAL_SECRETS_PROJECT" --domain https://eu.infisical.com \
  --env secrets --path /login-code -- login-code --after "$t" --wait 120 noreply@github.com "$d/code"
```

On a PC, where the Infisical CLI has its own login, drop the `INFISICAL_TOKEN`
prefix and the two flags before `--env`. `login-code --help` lists the options;
`--pattern` takes the code's regular expression when it is not 6 digits.

Setup, once:

1. Create the login-code mailbox, a Google account with 2-Step Verification
   on, and an app password for it.
2. Store the address as `LOGIN_CODE_IMAP_USER` and the app password as
   `LOGIN_CODE_IMAP_PASSWORD` in Infisical `personal-secrets`, env `secrets`,
   folder `/login-code`.
3. In Omer's Gmail, add the mailbox as a forwarding address and confirm it.
4. For each site, add a Gmail filter with `from:<sender>` that forwards to the
   mailbox.

A new site needs only step 4.

## Security model

Whoever drives the box browser acts as every account signed in there. The
design keeps the accounts that would let an attacker take over others out of
it, and accepts the rest.

- **Who can drive it.** DevTools has no password, so every process of devbox's
  user and root can drive the browser. That includes every agent, any session
  that logs in with a key in that user's `~/.ssh/authorized_keys` (the Grok
  bots' key among them, [devbox](devbox.md#access)), and the herdr web UI on
  the tailnet. The other local user `sl-factory` cannot: the firewall rejects its
  packets to loopback ([Factory run user](devbox.md#factory-run-user)), and the
  X cookie keeps it off the display.
- **What it holds.** No saved password: the policy turns the password manager
  off, and passwords live in Infisical, from which agents type them through
  `eval --stdin`. No mail account: codes come through `login-code`, which
  downloads only the named sender's mails and writes only a short code. The
  From header it matches is not authenticated, so a mail that forges the
  sender reaches the mailbox only if Gmail's filter forwards it.
- **Prompt injection.** Agents read untrusted pages. A page that tells an agent
  to read a sign-in code finds no mailbox in the browser, the attack Brave
  showed against Perplexity Comet
  ([brave.com/blog/comet-prompt-injection](https://brave.com/blog/comet-prompt-injection/)).
  The agent-browser skill lists the actions an agent asks Omer about first.
- **The profile at rest.** Chromium runs with `--password-store=basic`,
  because devbox has no keyring. Chromium then encrypts cookies with a fixed
  key (`kV10Key`, PBKDF2 of "peanuts", in Chromium's
  [posix_key_provider.cc](https://chromium.googlesource.com/chromium/src/+/main/components/os_crypt/async/browser/posix_key_provider.cc)),
  and devbox's disk has no disk encryption, so anyone with a copy of the disk
  reads the cookies. A keyring would not stop the agents either, because the
  same user unlocks it.
- **Omer's Brave.** No command forwards a PC's browser to devbox, so nothing
  on devbox reaches it. On the PC, Brave asks Allow for each new session.
- **Left out.** A VM or a second user for the browser would not separate it
  from the agents, which need DevTools. agent-browser refuses its domain
  allowlist in `--cdp` mode and calls it "not an OS firewall"
  ([agent-browser.dev/security](https://agent-browser.dev/security)).
  Device-bound sessions have no Linux support.
- **The display.** Xvnc takes the X cookie in `~/.Xauthority` (`-auth
  %h/.Xauthority`, a new cookie at each start from `box-display-prepare`).
  `box-browser.service` sets `XAUTHORITY=%h/.Xauthority`, because Plasma puts
  its own `XAUTHORITY` (`/run/user/<uid>/xauth_*`) into the user manager's
  environment and a unit would otherwise read that file, which has no cookie
  for `:20`. Xvnc has no password, because anyone who reaches `127.0.0.1:5920`
  is already a local user who can drive the browser through DevTools. Do not
  publish either port with `tailscale serve` or open it in a firewall. The
  viewer's SSH tunnel carries the VNC traffic, and SSH encrypts it.

## Check

`ci/checks.sh` reads devbox's system through `ci/box-browser.nix`. It fails
when a unit is missing, when the display command loses `-localhost` or
`-SecurityTypes None`, and when the browser unit's `DISPLAY` and `XAUTHORITY` are
not the display and the `-auth` file of that command line. devbox's boot test
(`ci/server-boot/checks/20-services.py`) starts the units, runs `box-browser
status`, checks that ports 5920 and 9344 listen on loopback only, and reads
`chrome://prefs-internals` in the box browser to check that the policy turns the
password manager off. On the host, `box-browser status` checks that both units
are active and that DevTools answers.
