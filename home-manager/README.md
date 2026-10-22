# Home Manager operator notes

Home Manager is integrated into the NixOS configuration of every host through
`nixosModules/home-manager.nix`. `oruc` gets `home-manager/common.nix` plus the
host layer in `machines/<host>/home.nix`. root gets only
`home-manager/modules/shell.nix`, so `sudo -i` has the same shell and tools. A
NixOS rebuild activates the matching user environment, and rolling back to a
retained NixOS generation rolls back its Home Manager generation too.

## Adding a module

A module that belongs to one desktop, shell or launcher turns itself on with
`sessions.hasDesktop`, `sessions.hasShell` or `cfg.launcher`. Other modules,
such as `shell.nix` and `git.nix`, apply on every host. The
[login sessions](../docs/architecture.md#login-sessions) section of the
architecture doc explains how session units bind to a desktop.

To add a shell or a launcher, follow
[Add a host, launcher, shell or kernel profile](../docs/architecture.md#add-a-host-launcher-shell-or-kernel-profile).
A launcher module must give the four commands that
`home-manager/modules/launchers/helpers.nix` lists (app, command, ssh and file).

## First activation and history

When Home Manager adopts a path that already exists, it moves that path to a
timestamped sibling such as `.zshrc.hm-backup-20260920T120000Z`. It does not
scan or change unrelated files. The two mime files that Home Manager owns,
`~/.config/mimeapps.list` and `~/.local/share/applications/mimeapps.list`, follow
the same rule. Existing Home Manager symlinks stay.

Atuin is local-only: sync and update checks are disabled, and no account is
configured. Do not import native Zsh history; a machine without an Atuin
database starts with a fresh local database. An existing Atuin database is
left intact rather than deleted automatically. Native Zsh history remains
enabled and includes failed commands. Up, Down, Ctrl-P and Ctrl-N search it by
the text typed so far (`history-substring-search`), and `fc -l` lists it. Atuin
owns Ctrl-R and does not take Up.

## Updates

On every host, every switch, manual or automatic, leaves the desktop shell, the
keyring, the Bluetooth applet and the idle service (swayidle) on their old
version (`X-SwitchMethod = "keep-old"` in `home-manager/modules/session-scope.nix`),
so an update does not restart the panel while you work. The next login starts
the new version. Open apps keep their old version until you restart them, and a
new kernel runs after the next boot.

## Per-host credentials

Keep these steps outside the repository:

1. Copy Omer's shared key `~/.ssh/id_ed25519_omer` and its `.pub` from another
   of his devices over SSH, mode 0600. GitHub already lists its public key. The
   key has a password. Save it in the host's KWallet, so the gcr ssh-agent
   unlocks the key on first use after each login:

   ```sh
   secret-tool store --label='Unlock password for: omer-all-devices' unique ssh-store:$HOME/.ssh/id_ed25519_omer
   ```
2. Run `gh auth login --git-protocol ssh` interactively. Store the resulting
   credential in the session Secret Service; never add `hosts.yml` to Git.
3. Enroll the shared public key as a GitHub signing key.
4. Put the host-local signing policy in `~/.config/git/local-signing.inc`:

   ```ini
   [gpg]
       format = ssh
   [user]
       signingKey = ~/.ssh/id_ed25519_omer.pub
   [commit]
       gpgSign = true
   ```

Do not commit private keys, Atuin keys/databases, GitHub credentials, or the
host-local signing include.

## Logins on a new laptop

Run the logins from another machine with `ssh -t <host>`. The host has no
browser over ssh, so you open the login page in the browser in front of you and
type the code there. gh, Codex and Claude Code each
need their own login. Behavior below was observed on nixos-rog on 2026-10-10.

- **gh.** Run `gh auth login --git-protocol ssh --web`. Over ssh the host has no
  clipboard tool and no display, so gh cannot copy its one-time code or open a
  browser. Type the code gh prints into your own browser, and ignore the
  browser launch error that follows. `--insecure-storage` keeps the token in
  `~/.config/gh/hosts.yml`; whether the Secret Service keyring is unlocked over
  ssh was not tested.
- **gh SSH key.** Skip the key that gh offers to generate during login, because
  the shared key `~/.ssh/id_ed25519_omer` is already on GitHub.
- **Codex.** Run `codex login --device-auth`.
- **Claude Code.** `~/.claude` takes `claude auth login`. Each extra account has
  its own folder and takes `CLAUDE_CONFIG_DIR=~/.claude-<name> claude auth login`.
  Do not copy a `.credentials.json` from another machine, because Claude Code
  rotates the refresh token on use and the first refresh on one machine logs
  the other out. The account folder layout is in `desktop/bin/guide.md` of the
  dotfiles checkout.
