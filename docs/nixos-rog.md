# nixos-rog

- [Hourly updater](#hourly-updater)
- [Failures and notifications](#failures-and-notifications)
- [Secrets](#secrets)
- [DNS](#dns)
- [Claude Code and Codex setup](#claude-code-and-codex-setup)
- [Check the running laptop](#check-the-running-laptop)

Boot entries, generations and the GPU mode are in [recovery.md](recovery.md#nixos-rog).

## Hourly updater

nixos-rog updates itself. The updater is `oruc-auto-update.service`. Every
hour on AC power, it runs `scripts/auto-update.sh` in its own clone of this
repository. Its timer adds up to 10 minutes of random delay. On battery the
service skips the run.

Each run collects its input and app changes into one update, and does these
steps:

1. It moves the release-tagged inputs except DMS with `update-release-tags.sh`.
2. It updates every other input except the kernel, nixpkgs, DMS and llm-agents.
3. It moves the kernel, nixpkgs, DMS and llm-agents by the rules in the table
   below.
4. It moves each app with `update-app.sh`. [updates.md](updates.md) has the
   kernel and app steps.
5. When no input or app moved, it logs "Everything is current." and deploys
   nothing.
6. It checks that every other host still evaluates. When one does not, the
   update fails with status 76.
7. It deploys the result to nixos-rog with `./deploy.sh nixos-rog switch`.
8. It squash-merges the result to `main` through the `auto-update` branch. The
   PR body holds dix's comparison of the old and new system.

A desktop notification reports each update or failure.

A change merged to `main` reaches nixos-rog with the next update that moves
something, or with a manual `./deploy.sh nixos-rog switch`.

| Input | When it moves |
| --- | --- |
| kernel | Only when a cache holds its build. `update-kernel.sh` moves it. |
| llm-agents | Only when a cache holds its builds. See the paragraph below. |
| nixpkgs and DMS | They wait up to a day for the cache to hold the DMS build. See [DMS and nixpkgs](#dms-and-nixpkgs). |

When the new llm-agents revision has a coding agent that cache.numtide.com does
not hold yet, or the run cannot tell, llm-agents stays where it is. So the
laptop does not compile an agent at full load. The next run tries again.

If `main` moves during the build, the host keeps the update. The next run
merges it on top of the new `main`.

A switch leaves the desktop shell, the keyring and other user services on their
old version. `home-manager/README.md` lists them.

`oruc-auto-update.service` reads a fine-grained GitHub token,
`github-update-token`, limited to this repository. The script passes it to git,
gh and Nix in its environment. So any process of `oruc` can read the token
while a run lasts.

To run the updater now and read its log:

```sh
ssh nixos-rog 'sudo systemctl start oruc-auto-update; journalctl -u oruc-auto-update -n 50'
```

### DMS and nixpkgs

Noctalia comes from nixpkgs, so the NixOS cache holds it. DankMaterialShell
(DMS) follows this flake's nixpkgs, so each new nixpkgs or DMS release needs a
new DMS build.

Every hour, the [shells-cache](../.github/workflows/shells-cache.yml) workflow
builds DMS for the head of nixos-unstable and the newest DMS release. It pushes
the build to the `omerfarukoruc` Cachix cache. GitHub emails a failed scheduled
run of that workflow.

The updater moves nixpkgs and the DMS tag only once that cache holds the build.
So nixpkgs updates can lag nixos-unstable by an hour or two, and the laptop
downloads DMS instead of compiling it.

After a day without that build, nixpkgs moves anyway and the laptop compiles
DMS. A notification says so once.

## Failures and notifications

The exit codes below come from `deploy.sh`, except 76. The
[exit-code table in deploy.md](deploy.md#exit-codes) says what each one means.

| Event | What happens | Notification |
| --- | --- | --- |
| GitHub cannot be reached | The run exits quietly. The next run tries again. | None |
| A clone or fetch fails while GitHub answers | It counts as a failure. | Critical |
| The deploy fails with 70, 71, 74 or 79 | The next run tries the same update again. | Critical |
| Any other failed update, such as status 76 | The run does not try that update again until `main` or an upstream moves. | Critical |
| Another deploy holds the lock (77) | The run stops without a failure. The next run tries again. | "Update waiting" from the second run in a row that 77 holds back |
| nixos-rog runs a release whose files `main` lacks (78) | The run stops without a failure. The next run tries again. | "Update waiting" from the first run that 78 holds back |
| The run reaches 2 hours | The service stops the run (`TimeoutStartSec`). | Critical |

Exit 70 means a pending rollback timer, 71 a rollback timer the deploy could not
arm, 74 a full ESP and 79 an unmounted `/boot`.

A clone or fetch fails while GitHub answers when, for example, the token
expired or was revoked, or the account lost access to the repository.

A stop during `deploy.sh` leaves the rollback timer armed. The timer restores
the previous system when it fires, at most 420 seconds after the deploy armed
it. The stopped run records no failed update, so the next run tries it again.
That run exits 70 if the rollback has not fired yet.

Some messages would repeat every hour, such as a failed app check or a build
that fails. The updater sends such a message once. It counts the message as
sent only when the desktop shows it. When no desktop session is running, the
next run sends it again.

## Secrets

`secrets/nixos-rog.yaml` holds the NextDNS profile ID (`nextdns-profile`) and
the updater's GitHub token (`github-update-token`). sops encrypts the file for
two recipients, which `.sops.yaml` lists:

- fedora-desktop's `~/.ssh/id_ed25519`
- the age key derived from the laptop's SSH host key

Edit the file on fedora-desktop with a `sops` binary from Nix:

```sh
SOPS_AGE_SSH_PRIVATE_KEY_FILE=~/.ssh/id_ed25519 sops secrets/nixos-rog.yaml
```

## DNS

DNS goes only to NextDNS over TLS.

The public names under `risoluto.dev` (`openchamber.risoluto.dev`,
`cliproxy.risoluto.dev`) point at Tailscale addresses. The profile's
DNS-rebinding protection answers those names with `0.0.0.0`. So the profile's
Allowlist in the NextDNS dashboard holds `risoluto.dev`. That entry also turns
off NextDNS filtering for that one domain.

Without the entry, OpenChamber and cliproxy fail to connect as if the server
were down. The `risoluto-dev-allowlisted` check in `scripts/verify-nixos-rog.sh`
also fails.

When a Wi-Fi sign-in page does not load, switch to the network's own plain DNS
until you are logged in. Then switch back. The first command switches, and the
second switches back:

```sh
sudo captive-dns on
sudo captive-dns off
```

A reboot also switches back.

## Claude Code and Codex setup

The Claude Code and Codex setup comes from the dotfiles checkout at
`~/Desktop/workspace/dotfiles`. Every hour, `desktop-sync-config.timer` runs
that checkout's `desktop/bin/desktop-sync.sh --config`. The script links the
rules, skills, hooks and agents. It also syncs Claude Code's `settings.json` in
both directions. Home Manager keeps the shell and tools.

The unit does nothing until that checkout exists.

## Check the running laptop

After a deploy, check the running laptop from fedora-desktop:

```sh
scripts/verify-nixos-rog.sh
```

The script writes a JSON report under `~/.local/state/nixos-config-verify/`.
It exits 1 when a check fails. `--suspend` adds three s2idle cycles.
