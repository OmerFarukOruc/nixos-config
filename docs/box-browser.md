# Box browser

`features.boxBrowser` gives a host one signed-in Chromium that coding agents
share. Omer signs in to a site once through a VNC viewer, and every agent session
then drives the same logins with agent-browser, each in its own tab.
`nixosModules/box-browser.nix` holds the box side and
`home-manager/modules/box-view.nix` the viewer side. devbox and nixos-desktop
turn the feature on in their records. On nixos-desktop it is the agents' browser
for signed-in work, because Omer's Brave asks him to Allow each new DevTools
client, so an agent that drives Brave stops while he is away.

## Turn it on

Set `features.boxBrowser = true` in the host's record in `machines/inventory.nix`
and deploy it. The feature needs no secret and no tailnet policy change: the
viewer reaches another host's Xvnc only through an SSH tunnel, over the host's
SSH alias, which Tailscale SSH already allows.

## What runs

- `box-display.service` (user unit) is Xvnc on display `:20`, listening on
  `127.0.0.1:5920` with no password (`-SecurityTypes None`) and the desktop name
  `box-browser`, which the viewer shows in its window title.
- `box-browser.service` (user unit) is nixpkgs Chromium on that display, with the
  profile in `~/.local/share/box-browser/profile` and DevTools on
  `127.0.0.1:9344`. Both units restart on failure, and a restart of the display
  restarts the browser. `users.users.<user>.linger` keeps them running without a
  login.
- `box-browser` (command) runs `agent-browser` against the DevTools port, with
  `AGENT_BROWSER_PIN_TAB=1`. It names the agent-browser session after
  `$CLAUDE_CODE_SESSION_ID`, unless the caller passes `--session` or sets
  `AGENT_BROWSER_SESSION`; with none of the three it exits 2. `box-browser status`
  checks that both units are active and that DevTools answers.
- `box-view` (command and menu entry "Box browser", on nixos-desktop and
  nixos-rog) opens the viewer on `127.0.0.1::5920`. For another host it runs
  `vncviewer -via <host>`, and TigerVNC's viewer opens the SSH tunnel itself
  with the command in `VNC_VIA_CMD`, which keeps `BatchMode` and
  `ExitOnForwardFailure`. A failure of the viewer or its tunnel also shows as a
  desktop notification, since the menu entry has no terminal.

The wrapper runs the first `agent-browser` on `PATH`, which Home Manager installs
from llm-agents.nix (`home-manager/modules/agent-cli.nix`).

## Sign in

Run `box-view <host>`, or open Box browser from the menu, and sign in to the
site in the Chromium window, then close the viewer. The session stays in that
host's profile. `box-view local` opens this host's own display with no tunnel,
and so does the host's own name. With no argument, a host with
`features.boxBrowser` opens its own display and any other host opens devbox's,
so name the host when the agent that needs the login drives another host's
browser.

## Limits

- Any process of the user, and root, can drive the browser through DevTools,
  which has no password. This is the purpose of the feature.
- Xvnc takes the X cookie in `~/.Xauthority` (`-auth %h/.Xauthority`, a new cookie
  at each start from `box-display-prepare`), so another local user cannot open
  the display through its X socket. `box-browser.service` sets
  `XAUTHORITY=%h/.Xauthority`, because Plasma puts its own `XAUTHORITY`
  (`/run/user/<uid>/xauth_*`) into the user manager's environment and a unit
  would otherwise read that file, which has no cookie for `:20`. Without `-auth`, Xvnc let any local user connect, abstract socket included.
- Xvnc has no password, because anyone who reaches `127.0.0.1:5920` on the host is
  already a local user who can drive the same Chromium through DevTools. On
  devbox, the other local user `sl-factory` cannot reach loopback because its
  packets are rejected (`docs/devbox.md`, Factory run user). The loopback bind is
  its only protection, so `ci/checks.sh` fails when the display
  command loses `-localhost` or `-SecurityTypes None`. Do not publish the port
  with `tailscale serve` or open it in a firewall.
- The viewer needs `ssh <host>` to work for another host, with the user the
  host's SSH alias sets. The tunnel carries the VNC traffic, and SSH encrypts
  it.

## Check

`ci/checks.sh` reads nixos-desktop's system through `ci/box-browser.nix`, checks
the unit names, the display's command line and the browser unit's `XAUTHORITY`, so it also fails when the
record turns the feature off. The check does not start the units; run
`box-browser status` on the host after the first deploy.
