# Home Manager operator notes

Home Manager is integrated into the NixOS configuration of every host through
`nixosModules/home-manager.nix`, for `oruc` and for root. A NixOS rebuild
activates the matching user environment, and rolling back to a retained NixOS
generation rolls back its Home Manager generation too. There is no separate
standalone Home Manager configuration or retention claim.

## First activation and history

When Home Manager adopts a path that already exists, it moves that path to a
timestamped sibling such as `.zshrc.hm-backup-20260920T120000Z`. It does not
scan or change unrelated files. The two mime files that Home Manager owns,
`~/.config/mimeapps.list` and `~/.local/share/applications/mimeapps.list`, follow
the same rule. Home Manager finds collisions from the generated configuration,
so a new managed path needs no second handwritten list. Existing Home Manager
symlinks stay.

Atuin is local-only: sync and update checks are disabled, and no account is
configured. Do not import native Zsh history; a machine without an Atuin
database starts with a fresh local database. An existing Atuin database is
left intact rather than deleted automatically. Native Zsh history remains
enabled, includes failed commands, and is available with Ctrl-P/Ctrl-N
(search by the text typed so far) or `fc -l`.

## Updates

On both hosts, every switch, manual or automatic, leaves the desktop shell, the
keyring, the Bluetooth applet and the idle service (swayidle) on their old
version (`X-SwitchMethod = "keep-old"` in `home-manager/modules/session-scope.nix`),
so an update does not restart the panel while you work. The next login starts
the new version. Open apps keep their old version until you restart them, and a
new kernel runs after the next boot.

## Per-host credentials

Keep these steps outside the repository:

1. Create a unique Ed25519 key in `~/.ssh` for this host and register only its
   public key with GitHub.
2. Run `gh auth login --git-protocol ssh` interactively. Store the resulting
   credential in the session Secret Service; never add `hosts.yml` to Git.
3. Enroll the host public key as a GitHub signing key.
4. Put the host-local signing policy in `~/.config/git/local-signing.inc`:

   ```ini
   [gpg]
       format = ssh
   [user]
       signingKey = ~/.ssh/id_ed25519_github.pub
   [commit]
       gpgSign = true
   ```

Do not commit private keys, Atuin keys/databases, GitHub credentials, or the
host-local signing include.
