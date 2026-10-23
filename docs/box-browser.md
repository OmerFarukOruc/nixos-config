# Box browser

`features.boxBrowser` gives a host one signed-in Chromium that coding agents
share. Omer signs in to a site once through a VNC viewer, and every agent session
then drives the same logins with agent-browser, each in its own tab.
`nixosModules/box-browser.nix` holds the box side and
`home-manager/modules/box-view.nix` the viewer side. No host turns the feature on
yet.

## Turn it on

Set `features.boxBrowser = true` in the host's record in `machines/inventory.nix`
and deploy it. The feature needs no secret and no tailnet policy change: the
viewer reaches Xvnc only through an SSH tunnel, which Tailscale SSH already
allows for `oruc@<host>`.

## What runs

- `box-display.service` (user unit) is Xvnc on display `:20`, listening on
  `127.0.0.1:5920` with no password (`-SecurityTypes None`) and the desktop name
  `box-browser`, which the viewer shows in its window title.
- `box-browser.service` (user unit) is nixpkgs Chromium on that display, with the
  profile in `~/.local/share/box-browser/profile` and DevTools on
  `127.0.0.1:9344`. Both units restart on failure, and a restart of the display
  restarts the browser. `users.users.oruc.linger` keeps them running without a
  login.
- `box-browser` (command) runs `agent-browser` against the DevTools port, with
  `AGENT_BROWSER_PIN_TAB=1`. It names the agent-browser session after
  `$CLAUDE_CODE_SESSION_ID`, unless the caller passes `--session` or sets
  `AGENT_BROWSER_SESSION`; with none of the three it exits 2. `box-browser status`
  checks that both units are active and that DevTools answers.
- `box-view` (command and menu entry "Box browser", on nixos-desktop and
  nixos-rog) opens the viewer. It starts `ssh -N -L <port>:127.0.0.1:5920
  oruc@<host>` on the first free local port from 5920, waits up to 15 seconds for
  the port, runs `vncviewer` on it, and stops the tunnel when the viewer exits. A
  failure of the tunnel or the viewer also shows as a desktop notification, since
  the menu entry has no terminal.

The wrapper runs the first `agent-browser` on `PATH`; this repository does not pin
one for the host.

## Sign in

Run `box-view`, or open Box browser from the menu. `box-view <host>` names another
host, and the default is `risoluto-dev-1`. Sign in to the site in the Chromium
window, then close the viewer. The session stays in the profile.

## Limits

- Any process of the user, and root, can drive the browser through DevTools,
  which has no password. This is the purpose of the feature.
- Xvnc has no password, because anyone who reaches `127.0.0.1:5920` on the host is
  already a local user who can drive the same Chromium through DevTools. The
  loopback bind is its only protection, so `ci/checks.sh` fails when the display
  command loses `-localhost` or `-SecurityTypes None`. Do not publish the port
  with `tailscale serve` or open it in a firewall.
- The viewer needs `ssh` access to `oruc@<host>`. The tunnel carries the VNC
  traffic, and SSH encrypts it.

## Check

CI evaluates the module although no host enables it. `ci/box-browser.nix` forces
the feature on for nixos-desktop, and `ci/checks.sh` builds that system's
`drvPath`, checks the unit names and checks the display's command line. The check
does not start the units; run `box-browser status` on the host after the first
deploy.
