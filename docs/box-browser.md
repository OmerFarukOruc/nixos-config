# Agent browsers

Coding agents drive signed-in browsers with agent-browser through one command,
`box-browser` (`pkgs/agent-tools/bin/box-browser`), installed on nixos-desktop,
nixos-rog and devbox. It reaches two kinds of browser, and on devbox the Grok
Bot app:

- A box browser: one Chromium on each of nixos-desktop, nixos-rog and devbox
  that every agent session on that host shares, each in its own tab. Agents
  use it by default, because it never waits for Omer, and they act in its
  signed-in sites without asking him. A PC's box browser holds Omer's own
  logins, his Google account among them, and saves passwords in KWallet.
  devbox's box browser holds the logins agents there need and Omer's Google
  account. It keeps the passwords Omer saves in it, so agents there sign in again
  without him; every process of devbox's user and root can drive it and read
  them.
- Omer's Brave Origin, on the PC he sits at, for an agent that runs on that
  PC. Brave asks him to click Allow for each new agent session, so agents use
  it only for a site that signs in only with a passkey. No agent on devbox
  reaches it.
- The Grok Bot app on devbox, one instance for each of Omer's two accounts,
  `personal` and `company` ([Grok Bot app](#grok-bot-app)). Grok Bot has no
  web chat, so the app is the only way to read a bot's chat, its Pages and its
  usage. Omer opens either instance from a PC with `box-view --app <account>`.

A page that needs no login opens in a throwaway headless browser
(`agent-browser --session <name>`) instead. The agent-browser skill
(`agents/skills/agent-browser/SKILL.md`) tells agents which browser to pick.

- [The command](#the-command)
- [Box browser](#box-browser)
- [Grok Bot app](#grok-bot-app)
- [Omer's Brave](#omers-brave)
- [Login codes](#login-codes)
- [Security model](#security-model)
- [Check](#check)

## The command

```sh
box-browser [--session NAME] [--on HOST] COMMAND...                  # box browser
box-browser [--session NAME] --brave COMMAND...                      # Omer's Brave
box-browser [--session NAME] [--on HOST] --app ACCOUNT COMMAND...    # Grok Bot app of that account
box-browser [--on HOST] [--app ACCOUNT] status                       # units and DevTools
box-browser [--on HOST] --app ACCOUNT start                          # start that account's app
```

COMMAND is an agent-browser command, such as `open <url>` or `snapshot -i`.
The session is `--session`, else `AGENT_BROWSER_SESSION`, else
`CLAUDE_CODE_SESSION_ID`, else `CODEX_THREAD_ID`; with none of them the
command exits 2. A session name holds only letters, digits, `-` and `_`.
Each session keeps its own pinned tab (`AGENT_BROWSER_PIN_TAB=1`). `--brave`
runs the session as `brave_<session>`, so its tab pin stays apart from the box
browser's, and a session name that starts with `brave_` exits 2.

Without `--brave`, the command drives this host's box browser when the host
runs `box-browser.service`, and devbox's over `ssh devbox` otherwise; `--on`
names another host, such as `--on devbox` from a PC. A command that arrives
over SSH without `XDG_RUNTIME_DIR` gets `/run/user/<uid>` for its
`systemctl --user` and `grok-bot-box-idle` calls. A file a box browser
writes, such as a screenshot, stays on the host that runs it. With `--brave`,
it drives this host's Brave Origin; it refuses `--on`, and it fails on a host
with no desktop session, such as devbox. The first `--brave` call of a session
waits up to 10 minutes for Omer's Allow click.

With `--app ACCOUNT`, the command drives the Grok Bot app that is signed in to
that account. It finds the app as it finds the box browser: this host's when
the host runs `grok-bot-box-<account>.service`, else devbox's over SSH. The
session runs as `app_<account>_<session>`, apart from the same agent's box
browser session, and a session name that starts with `app_` exits 2. The app has one window and no tabs, so its sessions share that
window and nothing is pinned, and `close` ends the session and leaves the app
running. Every command but `close` starts the app when it is stopped and
waits for its chat or its sign-in screen ([Grok Bot app](#grok-bot-app)); `start` does only that,
and `box-view --app` calls it. `--app` with `--brave` exits 2.

The command runs the first `agent-browser` on `PATH`, which Home Manager
installs from llm-agents.nix (`home-manager/modules/agent-cli.nix`).

## Box browser

`features.boxBrowser` in a host's record in `machines/inventory.nix` turns it
on; nixos-desktop, nixos-rog and devbox set it. `nixosModules/box-browser.nix`
holds the units, and `home-manager/modules/box-view.nix` the viewer.
The feature needs no secret and no tailnet policy change. A host that turns it
off keeps the signed-in profile in `~/.local/share/box-browser`; delete that
folder there.

- `box-display.service` (user unit) is Xvnc on display `:20`, listening on
  `127.0.0.1:5920` with no password (`-SecurityTypes None`) and the desktop name
  `box-browser`, which the viewer shows in its window title.
- `box-browser.service` (user unit) is nixpkgs Chromium on that display, with
  the profile in `~/.local/share/box-browser/profile` and DevTools on
  `127.0.0.1:9344`. Both units restart on failure, and a restart of the display
  restarts the browser.
- On a PC, both units are part of `graphical-session.target`, so they run while
  Omer is logged in to his desktop, and Chromium keeps the key of its cookies
  and saved passwords in KWallet (`--password-store=kwallet6`), as Brave does.
  Chromium falls back to its fixed key when the wallet is closed, so the
  browser waits until the wallet is open (`box-browser-wallet-open`): at login
  on nixos-rog, and at Omer's first unlock after boot on nixos-desktop, which
  logs in by itself.
- On devbox, `users.users.<user>.linger` keeps them running without a login.
  devbox has no Plasma session, so `nixosModules/box-browser.nix` starts
  Chromium with `--password-store=basic` instead of KWallet. Its password
  manager keeps Chromium's default, on, so the profile offers to save the
  passwords Omer types there, and he can turn that off in its settings
  ([Security model](#security-model)).
- `box-view` (command and menu entry "Box browser", on nixos-desktop and
  nixos-rog) opens the viewer on `127.0.0.1::5920`. For another host it
  forwards a socket in `$XDG_RUNTIME_DIR` (mode 0700, so no other local user
  reaches it) to the host's `127.0.0.1:5920` with `ssh -N -L`, which keeps
  `BatchMode` and `ExitOnForwardFailure`, and opens the viewer on that socket.
  A failure of the viewer or its tunnel also shows as a desktop notification,
  since the menu entry has no terminal.
- `browser-lend-off.service` (a NixOS oneshot on nixos-rog and nixos-desktop)
  removes any `tailscale serve` listener on tailnet ports 9222 and 9223, the
  ports that once published Brave's DevTools, because tailscaled keeps them
  across restarts, and fails when they remain.

To sign in, run `box-view`, or open Box browser from the menu, sign in to the
site in the Chromium window, click Save when Chromium offers to save the
password, then close the viewer. The session and the saved password stay in
the host's profile. With no argument the viewer opens the host's own box
browser; `box-view devbox` opens devbox's. Agents sign in by themselves when
Chromium fills a saved password or a secret store holds it, as the
agent-browser skill says, so Omer signs in only to what neither holds or what
needs a passkey or a captcha. When a site sends a sign-in code, the agent asks
Omer for it and enters it.

`box-browser close` closes the session's own tab, or blanks it when it is the
browser's last, before it ends the session; the agent closes any other tab it
opened first.

## Grok Bot app

`features.grokBotBox` in a host's record turns it on; devbox sets it.
`nixosModules/grok-bot-box.nix` holds the units, and the app is the package the
PCs install (`pkgs/grok-bot.nix`).

Each account gets three user units, and an idle check
(`grok-bot-idle-<account>.timer` and `.service`) beside them:

| Unit | Runs | personal | company |
|---|---|---|---|
| `grok-bot-display-<account>` | Xvnc, localhost only, no password | display `:21`, VNC `127.0.0.1:5921` | display `:22`, VNC `127.0.0.1:5922` |
| `grok-bot-wm-<account>` | ratpoison, a window manager | on `:21` | on `:22` |
| `grok-bot-box-<account>` | the app | DevTools `127.0.0.1:9345` | DevTools `127.0.0.1:9346` |

- `nixosModules/grok-bot-accounts.nix` holds the display and the two ports of
  each account, for the units and for `box-view`. `/etc/grok-bot-box/<account>.port`
  holds the DevTools port, which `box-browser --app` reads.
- Each account has a display of its own, so `box-view` shows one account and
  the two windows never cover each other. Without a window manager the app's
  window stays 512x520, so ratpoison stretches it over the 1920x1080 display.
  Its command key is Ctrl+F12, which leaves Ctrl+T to the app. ratpoison also
  takes over a window that opened before it started, so the app and the
  window manager start in either order.
- The app ignores `--user-data-dir`. It keeps its profile and its
  single-instance lock in `$XDG_CONFIG_HOME/Grok Bot`, so each app unit sets
  `XDG_CONFIG_HOME` to `~/.local/share/grok-bot-box/<account>`, and the two
  instances run side by side, each with its own login. The login survives a
  restart of the app with `--password-store=basic`, with no keyring.
- No unit starts at boot. The first `box-browser --app <account>` command or
  `box-view --app <account>` starts that account's app unit, which pulls in
  its display, its window manager and `grok-bot-idle-<account>.timer`; a start
  took under 10 s on devbox on 2026-11-20 and kept the login. Every 5 minutes
  the timer runs `grok-bot-box-idle check`, which stops the display, and with
  it the window manager, the app and the timer, once the account has been
  unused for 30 minutes. `$XDG_RUNTIME_DIR/grok-bot-box/<account>.used` holds
  the time of the last use: every `box-browser --app` call but `status` and
  `close` sets it (`grok-bot-box-idle used`), and so does a check that finds a connection to
  the VNC port or the DevTools port. A check that stops the display removes
  the file, and a missing file counts as used now. The check samples the two
  ports instead of proxying them, because one display has two ports and
  `systemd-socket-proxyd --exit-idle-time` watches one. A bot and
  its routines run on the vendor's servers, so a stopped app stops nothing of
  theirs. An agent's session counts as a connection until `close`, or until
  agent-browser ends it after 10 idle minutes
  (`AGENT_BROWSER_IDLE_TIMEOUT_MS`, which the command sets).
- Linger keeps a started unit running after the SSH login that started it
  ends. While running, each unit restarts on failure, and a restart of a
  display restarts its window manager and its app. The app unit stops with
  `SIGINT`, because the app dumps core on `SIGTERM`.
- `box-view --app <account>` (and the menu entries "Grok Bot on devbox:
  personal" and "Grok Bot on devbox: company", on nixos-desktop and
  nixos-rog) opens the viewer on that account's display on devbox, through the
  same SSH tunnel as the box browser's. `box-view <host> --app <account>`
  names another host.
- A host that turns the feature off keeps both profiles in
  `~/.local/share/grok-bot-box`; delete that folder there.

To sign an account in, an agent clicks Sign in and then Copy link in the app,
reads the link with `eval 'navigator.clipboard.readText()'` into a 0600 file,
and opens it in a browser that is signed in to that account at cursor.com. The
app polls until that page confirms, so the browser can be on any machine: an
agent opens the link in devbox's box browser when that browser holds the
account. Otherwise Omer runs `box-view --app <account>`, clicks Copy link
there and opens the link in his own browser. The link is a sign-in secret, so
it goes to a file and never into a report. The first sign-in of an account
passes cursor.com's "Enable data sharing" page, whose Share Data switch starts
on; that choice is Omer's.

```sh
box-browser --app company snapshot -i     # the app's controls
box-browser --app company status          # the three units and DevTools, or "stopped"
box-browser --app company start           # start it and wait for DevTools, with no session
box-view --app company                    # the app's window, on a PC
```

A routine with a webhook trigger starts work on a bot without the app: a POST
to the routine's URL with its key as a bearer token and a JSON body, which the
bot receives with the routine's instruction
([docs.x.ai](https://docs.x.ai/grok-bot/skills-routines-and-automations)).
The answer is `200` when the run started, and nothing of the bot's reply, so a
task that must read the reply uses the app.

## Omer's Brave

On nixos-desktop and nixos-rog, `box-browser --brave` drives the local Brave
Origin. Turn on `brave://inspect/#remote-debugging` once; Brave Origin then
writes its port and path to
`~/.config/BraveSoftware/Brave-Origin/DevToolsActivePort`, which the command
reads, because its `/json` answers 404.

## Login codes

By default an agent asks Omer for a code a site sends, because the
agent-browser skill's mail rule keeps agents out of Gmail. Optionally, a Gmail filter forwards the code mails of each
named sender to a separate login-code mailbox, and agents fetch the code
themselves. `login-code`
(`pkgs/agent-tools/bin/login-code`) reads that mailbox read-only over IMAP,
downloads only the sender's mails, and writes only the code, 4 to 12 letters,
digits or dashes, to a 0600 file, so no agent reads a mail. Take the time
before you request the code, so an older code does not count:

```sh
d=$(mktemp -d) && t=$(date +%s)
# request the code on the site, then:
infisical run --projectId "$INFISICAL_PERSONAL_SECRETS_PROJECT" --domain https://eu.infisical.com \
  --env secrets --path /login-code -- login-code --after "$t" --wait 120 noreply@github.com "$d/code"
```

It runs on a PC, where the Infisical CLI has Omer's login; devbox's
`omer-machines` identity reads only `/harness/**`, so it cannot read
`/login-code`. `login-code --help` lists the options;
`--pattern` takes the code's regular expression when it is not 6 digits.

Setup, once:

1. Create the login-code mailbox, a Google account with 2-Step Verification
   on, and an app password for it.
2. Store the address as `LOGIN_CODE_IMAP_USER` and the app password as
   `LOGIN_CODE_IMAP_PASSWORD` in Infisical `personal-secrets`, env `secrets`,
   folder `/login-code`.
3. Omer, in his Gmail: add the mailbox as a forwarding address and confirm it.
4. For each site, add a Gmail filter with `from:<sender>` that forwards to the
   mailbox.

A new site needs only step 4.

## Security model

Whoever drives a box browser acts as every account signed in there, and
agents act there without asking Omer. DevTools has no password and listens on
loopback only, so who can drive a box browser is who runs on its host.

- **A PC's box browser.** Only Omer's user and root on that PC can drive it,
  the same processes that already reach his files, his SSH keys and his
  Brave: the `owner-loopback` nftables table rejects other local users, such as
  the Nix build users, on the loopback ports in `oruc.ownerLoopbackPorts`
  (`nixosModules/owner-loopback.nix`), which are 5920 and 9344 there. devbox,
  whose firewall runs on iptables, gets the same rule as its
  `owner-loopback-out` chain. A switch from a system whose chain had another
  name keeps that chain and its `OUTPUT` jump beside the new one until the
  next reboot. No other host reaches
  it. It holds his own logins, his Google
  account among them, and its saved passwords and cookies are encrypted with
  a key in KWallet, so a copy of the profile without his login is useless.
- **Who can drive devbox's.** Every process of devbox's user and root can
  drive the browser. That includes every agent, any session
  that logs in as that user over SSH or Tailscale SSH, the Grok bots'
  tailnet device among them ([devbox](devbox.md#access)), and the herdr web
  UI on the tailnet. Other local users cannot: the `owner-loopback-out` chain
  rejects their connections to ports 5920 and 9344, and the firewall rejects
  `sl-factory`'s loopback packets other than DNS
  ([Factory run user](devbox.md#factory-run-user)), and the X cookie keeps it
  off the display.
- **What devbox's holds.** Saved passwords: Omer saves the passwords of the
  sites agents use there, so Chromium can fill them on the sign-in page. They
  sit under the same fixed key as the cookies (devbox's profile at rest,
  below), so any process of devbox's user or root can read them from disk, and
  an agent that drives the browser can read a filled password field. Other passwords live in Infisical,
  from which agents type them through `eval --stdin`. The browser also holds
  Omer's Google account, so any process that drives it or reads a disk copy
  can use his Google account and his Gmail; only the agent-browser skill's
  mail rule keeps agents out of Gmail. Omer gives a texted code, and an emailed
  code comes from him or from `login-code`, which reads the separate
  login-code mailbox, downloads only the named sender's mails and writes only
  a short code. The From header it matches is not authenticated, so a mail
  that forges the sender reaches the login-code mailbox only if Gmail's filter
  forwards it. The TOTP setup
  key of the GitHub account `statuslantern-tailscale` sits in Infisical
  `/harness/box-browser`, so any process of devbox's user can compute that
  account's 2FA code and pass GitHub's sudo mode in the signed-in session
  ([devbox reference, Browsers](../agents/reference/devbox.md#browsers)). Once
  Omer saves that account's password here too, devbox holds both of its
  factors, and its 2FA no longer protects it against a process on devbox.
- **devbox's Grok Bot accounts.** The same processes can drive both app
  instances, so each of them acts as Omer's personal Grok Bot account and as
  his company's: it can read every bot's chats and Pages, message a bot, and
  change its routines and connections. The `owner-loopback-out` chain keeps
  other local users off the VNC ports 5921 and 5922 and the DevTools ports
  9345 and 9346. Each profile keeps its login without a keyring
  (`--password-store=basic`), so a copy of the disk holds both logins, as it
  holds the box browser's.
- **Prompt injection.** Agents read untrusted pages. A page that tells an agent
  to read a sign-in code or open Gmail, the attack Brave showed against
  Perplexity Comet
  ([brave.com/blog/comet-prompt-injection](https://brave.com/blog/comet-prompt-injection/)),
  meets a browser that holds Gmail, on devbox as on a PC.
  Agents act in signed-in sites without asking, so a page can also steer an
  agent into a change in GitHub, AWS, Cloudflare or Tailscale, such as a new
  token or a changed recovery address, or into reading a saved password from a
  filled field. Only the agent-browser skill's mail rule keeps agents out of
  Gmail, in every box browser.
- **devbox's profile at rest.** Chromium runs with `--password-store=basic`,
  because devbox has no Plasma session and so no KWallet. Chromium then encrypts cookies and saved
  passwords with a fixed key (`kV10Key`, PBKDF2 of "peanuts", in Chromium's
  [posix_key_provider.cc](https://chromium.googlesource.com/chromium/src/+/main/components/os_crypt/async/browser/posix_key_provider.cc)),
  and devbox's disk has no disk encryption, so anyone with a copy of the disk
  reads the cookies and the saved passwords. A keyring would not stop the
  agents either, because the same user unlocks it.
- **Omer's Brave.** No command forwards a PC's browser to devbox, so nothing
  on devbox reaches it. On the PC, Brave asks Allow for each new session. Omer
  is signed in to Gmail there, and only the agent-browser skill's rule keeps
  agents out of it.
- **Left out.** A VM or a second user for the browser would not separate it
  from the agents, which need DevTools. agent-browser refuses its domain
  allowlist in `--cdp` mode and calls it "not an OS firewall"
  ([agent-browser.dev/security](https://agent-browser.dev/security)).
  Device-bound sessions have no Linux support.
- **The display.** Xvnc takes the X cookie in `~/.Xauthority` (`-auth
  %h/.Xauthority`, a new cookie at each start from `vnc-display-prepare`;
  `nixosModules/vnc-display.nix` builds this unit and the Grok Bot displays).
  `box-browser.service` sets `XAUTHORITY=%h/.Xauthority`, because Plasma puts
  its own `XAUTHORITY` (`/run/user/<uid>/xauth_*`) into the user manager's
  environment and a unit would otherwise read that file, which has no cookie
  for `:20`. Xvnc has no password, because anyone who reaches `127.0.0.1:5920`
  is already a local user who can drive the browser through DevTools. Do not
  publish either port with `tailscale serve` or open it in a firewall. The
  viewer's SSH tunnel carries the VNC traffic, and SSH encrypts it.

## Check

`ci/checks.sh` reads the systems of devbox, nixos-rog and nixos-desktop
through `ci/box-browser.nix`. It fails when a unit is missing, when the display
command loses `-localhost` or `-SecurityTypes None`, when the browser unit's
`DISPLAY` and `XAUTHORITY` are not the display and the `-auth` file of that
command line, when a Plasma host's browser does not wait for the wallet or
keeps its key anywhere but KWallet, when another host's browser does not use
Chromium's fixed key, and when the browser does not start with the desktop
session on a host that has one, or at boot on one without. Each host job also
checks the user units for an ordering cycle. devbox's boot test
(`ci/server-boot/checks/20-services.py`) starts the units, runs `box-browser
status`, checks that ports 5920 and 9344 listen on loopback only and that its
user reaches them while `nobody` does not, and checks that `close` closes only
the session's tab, or blanks it when it is the browser's last. On the host,
`box-browser status` checks that both units are active and that DevTools
answers.

The same evaluation check fails when the box browser's VNC or DevTools port
is missing from `oruc.ownerLoopbackPorts`, and when a Grok Bot unit takes
DevTools off `127.0.0.1`, runs on a display that is not its own `-localhost`
Xvnc with `-SecurityTypes None`, shares a port or its profile folder with the
other unit, or uses a port that the list or its `/etc/grok-bot-box` file does
not name, when a target wants one of an account's units or its timer, which
would start it at boot, or when the app unit does not want its idle timer or
that timer does not stop with the display. The boot test turns `features.grokBotBox` off
(`ci/server-boot/modules/grok-bot-box.nix`), because its VM has 1024 MB and
the two apps held 842 MB while idle on devbox on 2026-11-20 (the `Pss` lines of
`/proc/<pid>/smaps_rollup` summed over their processes, which counts shared
memory once; systemd's `MemoryCurrent` showed 182 MB and 191 MB for the two app
units, with peaks of 350 MB and 282 MB), so the Grok Bot units are checked on devbox
after a deploy: `box-browser --app <account> start` starts an account, and
`box-browser --app <account> status` then shows its three units and DevTools.
