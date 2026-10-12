# nixos-rog

Boot entries, generations and the GPU mode are in [recovery.md](recovery.md#nixos-rog).

## Hourly self-update

nixos-rog updates itself. Every hour on AC power, `oruc-auto-update.service`
runs `scripts/auto-update.sh` in its own clone of this repository. It updates
every input except the kernel, nixpkgs, DMS and llm-agents. The kernel and
llm-agents move only when a cache holds their builds, and nixpkgs and DMS wait
for the cache for up to a day. The kernel moves through `update-kernel.sh`,
and the other three as described below ([updates.md](updates.md) has the kernel and app steps). The run also moves the release-tagged inputs
with `update-release-tags.sh` and each app with `update-app.sh`, checks that
every other host still evaluates, deploys the result to nixos-rog with
`./deploy.sh nixos-rog switch`, and squash-merges it to `main` through the
`auto-update` branch, with dix's comparison of the old and new system in the
PR body. A desktop notification reports each update or failure. A message
that would repeat every hour (a failed app check, a build that fails) is sent
once, and only after a notification was shown; when no desktop session is
running, the run sends it again next time.
When GitHub cannot be reached, the run exits quietly and tries again next time.
A clone or fetch that fails while GitHub answers (an expired or revoked token,
lost access to the repository) is a failure and sends a critical notification.
The service stops a run after 2 hours (`TimeoutStartSec`) and the script sends
a notification. A stop during `deploy.sh` leaves its rollback timer to restore
the previous system after 5 minutes. The stopped run records no failed
candidate, so the next run tries it again, and exits 70 if the rollback has not
fired yet.
A run where no input or app moved logs "Everything is current." and deploys
nothing, so a change merged to `main` reaches nixos-rog with the next update
or with a manual `./deploy.sh nixos-rog switch`.
A candidate that failed is not tried again until `main` or an upstream moves,
unless deploy.sh stopped for a pending rollback timer (exit 70), a rollback
timer it could not arm (exit 71), a full ESP (exit 74), or an unmounted `/boot`
(exit 79). A candidate where another host
no longer evaluates fails with exit 76. When another deploy holds the lock (exit 77) or nixos-rog runs a
release whose files `main` lacks (exit 78), the run stops without a failure and
the next run tries again. The first run that exit 78 holds back sends an
"Update waiting" notification, and so does a second run in a row that exit 77
holds back.

When the new llm-agents revision has a coding agent that cache.numtide.com
does not hold yet, or the run cannot tell, llm-agents stays where it is, so
the laptop does not compile an agent at full load; the next run tries again.

Noctalia comes from nixpkgs, so the NixOS cache holds it. DankMaterialShell
follows this flake's nixpkgs, so each new nixpkgs or DMS release needs a new
DMS build. Every hour the
[shells-cache](../.github/workflows/shells-cache.yml) workflow builds it
for the head of nixos-unstable and the newest DMS release and pushes it to the
`omerfarukoruc` Cachix cache. The run moves nixpkgs and the DMS tag only once
that cache holds the build, so nixpkgs updates can lag nixos-unstable by an
hour or two, and the laptop downloads DMS instead of compiling it. After a day
without that build, nixpkgs moves anyway, the laptop compiles DMS, and a
notification says so once. GitHub emails a
failed scheduled run of that workflow.

If `main` moves during the build, the host keeps the update and the next run
merges it on top of the new `main`. A switch leaves the desktop shell, the
keyring and other user services on their old version; `home-manager/README.md`
lists them.

`oruc-auto-update.service` reads a fine-grained GitHub token,
`github-update-token`, limited to this repository. The script passes it to git,
gh and Nix in its environment, so any process of `oruc` can read it while a run
lasts. Its timer adds up to 10 minutes of random delay. On battery the service
skips the run. To run it now and read its log:

```sh
ssh nixos-rog 'sudo systemctl start oruc-auto-update; journalctl -u oruc-auto-update -n 50'
```

## Secrets

`secrets/nixos-rog.yaml` holds the NextDNS profile ID (`nextdns-profile`) and the
updater's GitHub token (`github-update-token`). It is encrypted with sops for
fedora-desktop's `~/.ssh/id_ed25519` and for the age key derived from the
laptop's SSH host key (recipients in `.sops.yaml`). Edit it on fedora-desktop
with a `sops` binary from Nix:

```sh
SOPS_AGE_SSH_PRIVATE_KEY_FILE=~/.ssh/id_ed25519 sops secrets/nixos-rog.yaml
```

## DNS

DNS goes only to NextDNS over TLS. The public names under `risoluto.dev`
(`openchamber.risoluto.dev`, `cliproxy.risoluto.dev`) point at Tailscale
addresses, and the profile's DNS-rebinding protection answers those with
`0.0.0.0`. So the profile's Allowlist in the NextDNS dashboard holds
`risoluto.dev`, which also turns off NextDNS filtering for that one domain.
Without the entry, OpenChamber and cliproxy fail to connect as if the server
were down, and the `risoluto-dev-allowlisted` check in
`scripts/verify-nixos-rog.sh` fails.

When a Wi-Fi sign-in page does not load, switch to the network's own plain DNS
until you are logged in, then back:

```sh
sudo captive-dns on
sudo captive-dns off
```

A reboot also switches back.

## Claude Code and Codex setup

The Claude Code and Codex setup comes from the dotfiles checkout at
`~/Desktop/workspace/dotfiles`. Every hour `desktop-sync-config.timer` runs its
`desktop/bin/desktop-sync.sh --config`, which links the rules, skills, hooks and
agents and syncs Claude Code's `settings.json` both ways; Home Manager keeps the
shell and tools. The unit does nothing until that checkout exists.

## Check the running laptop

After a deploy, check the running laptop from fedora-desktop. The script writes
a JSON report under `~/.local/state/nixos-config-verify/` and exits 1 when a
check fails; `--suspend` adds three s2idle cycles:

```sh
scripts/verify-nixos-rog.sh
```
