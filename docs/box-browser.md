# Box browser

`features.boxBrowser` gives a host one signed-in Chromium that coding agents
share. Omer signs in to a site once through a VNC viewer, and every agent session
then drives the same logins with agent-browser, each in its own tab.
`nixosModules/box-browser.nix` holds the whole feature. No host turns it on yet.

## Turn it on

1. Set `features.boxBrowser = true` in the host's record in
   `machines/inventory.nix`. The host must enable Tailscale (the module asserts
   it) and set `sops.defaultSopsFile` and an age key for sops-nix, as
   `machines/nixos-desktop/configuration.nix` does.
2. Add the VNC password to the host's `secrets/<host>.yaml` as
   `box-vnc-password`. The command reads it from a hidden prompt and keeps it out
   of the process list. [Secrets](nixos-rog.md#secrets) explains the key file and
   `scripts/check-secrets.sh`.

   ```sh
   read -rs pw && printf '%s' "$pw" | jq -R . | SOPS_AGE_SSH_PRIVATE_KEY_FILE=~/.ssh/id_ed25519_omer nix shell nixpkgs#sops -c sops set --value-stdin secrets/<host>.yaml '["box-vnc-password"]'; unset pw
   ```

3. Allow the viewer's devices to reach port 5920 of the host in the tailnet
   policy.

## What runs

- `box-display.service` (user unit) is Xvnc on display `:20`, listening on
  `127.0.0.1:5920` with the password from step 2.
- `box-browser.service` (user unit) is nixpkgs Chromium on that display, with the
  profile in `~/.local/share/box-browser/profile` and DevTools on
  `127.0.0.1:9344`. Both units restart on failure, and a restart of the display
  restarts the browser. `users.users.oruc.linger` keeps them running without a
  login.
- `box-display-tailnet.service` (system unit) runs `tailscale serve` so that the
  host's tailnet name answers on port 5920.
- `box-browser` (command) runs `agent-browser` against the DevTools port, with
  `AGENT_BROWSER_PIN_TAB=1`. It names the agent-browser session after
  `$CLAUDE_CODE_SESSION_ID`, unless the caller passes `--session` or sets
  `AGENT_BROWSER_SESSION`; with none of the three it exits 2. `box-browser status`
  checks that both units are active and that DevTools answers.

The wrapper runs the first `agent-browser` on `PATH`; this repository does not pin
one for the host.

## Sign in

From nixos-desktop or nixos-rog, run `vncviewer <host>:5920`. tigervnc is in
`home-manager/profiles/personal.nix`. Sign in to the site in the Chromium window,
then close the viewer. The session stays in the profile.

## Limits

- Any process of the user, and root, can drive the browser through DevTools,
  which has no password. This is the purpose of the feature.
- VNC password authentication uses only the first 8 characters of the password.
  The VNC traffic travels inside the tailnet.

## Check

CI evaluates the module although no host enables it. `ci/box-browser.nix` forces
the feature on for nixos-desktop, and `ci/checks.sh` builds that system's
`drvPath` and checks the unit names. The check does not start the units; run
`box-browser status` on the host after the first deploy.
