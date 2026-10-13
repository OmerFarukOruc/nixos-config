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

1. It moves every input that the table below does not name with
   `move-inputs.sh`.
2. It moves the inputs in the table by the rules there.
3. It moves each app with `update-app.sh`. [updates.md](updates.md) has the
   input, kernel and app steps.
4. When no input or app moved, it logs "Everything is current." and deploys
   nothing.
5. It checks that every other host still evaluates. When one does not, the
   update fails with status 76.
6. It deploys the result to nixos-rog with `./deploy.sh nixos-rog switch`.
7. It squash-merges the result to `main` through the `auto-update` branch. The
   PR body holds dix's comparison of the old and new system.

A desktop notification reports each update or failure.

A change merged to `main` reaches nixos-rog with the next update that moves
something, or with a manual `./deploy.sh nixos-rog switch`.

| Input | When it moves |
| --- | --- |
| kernel | Only when a cache holds its build. `update-kernel.sh` moves it. |
| llm-agents | Only when a cache holds its builds. See the paragraph below. |
| nixpkgs, dms, silent-sddm and sops-nix | They wait up to a day for the cache to hold the packages built from them. See [Cached packages](#cached-packages). |

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

### Cached packages

cache.nixos.org does not hold the packages that come from this flake's own
inputs, overlays or settings. `ci/cached-packages.nix` lists the free ones of
each host: DankMaterialShell (DMS), Deskflow, the Glass KWin effect and Qt
style, the SilentSDDM theme and `sops-install-secrets`, plus the newer
libportal that Deskflow links. It reads them from the host's own
configuration, so they are the exact builds the host would compile.

Every hour, the [host-packages-cache](../.github/workflows/host-packages-cache.yml)
workflow moves the inputs with the same `move-inputs.sh`, builds the packages
that the caches lack and pushes them to the `omerfarukoruc` Cachix cache. It
also builds them for every push to `main`, so a later deploy of nixos-latitude
downloads them. On a pull request it builds them and runs the closure check
without pushing, so a change that would keep a package out of the cache fails
there. GitHub emails a failed scheduled run of that workflow.

The updater moves the inputs those packages come from only once the cache
holds every package this host uses. So nixpkgs updates can lag nixos-unstable
by an hour or two, and the laptop downloads the packages instead of compiling
them.

After a day without those builds, the inputs move anyway and the laptop
compiles the packages. A notification says so once.

whisper-cpp is not in the list. Its CUDA build references NVIDIA libraries
that are unfree, and `cachix push` uploads a whole closure, so the laptop
compiles it when nixpkgs changes it.

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
both directions. Home Manager keeps the shell and tools, and adds one entry,
`~/.claude/skills/claude-code-home-manager`, a plugin that gives Claude Code the
`nixos` MCP server from `home-manager/modules/applications.nix`.

The unit does nothing until that checkout exists.

## Power and heat

Six services share the laptop's power settings. Each setting has one owner:

| Setting | Set in | Applied by |
|---|---|---|
| power profile, EPP, CPU boost | `nixosModules/peripherals.nix` | power-profiles-daemon |
| power limits, NVIDIA limits, fan curves | `machines/nixos-rog/asus.nix`, `fan-curves.json` | asusd, on each profile change |
| CPU temperature limit, top clock | `machines/nixos-rog/cpu-limits.nix` | `oruc-cpu-limits` |
| power-saver on low battery | `machines/nixos-rog/low-battery.nix` | `oruc-low-battery` |
| NVIDIA Dynamic Boost | `machines/nixos-rog/graphics.nix` | nvidia-powerd, which asusd runs on AC |
| scheduler power mode | `machines/nixos-rog/configuration.nix` | scx_lavd `--autopower` |

Facts that matter when you change or measure them:

- `powerprofilesctl set` over SSH needs `sudo`; polkit refuses it otherwise.
- The profile you pick stays after a reboot, because power-profiles-daemon
  saves it in `/var/lib/power-profiles-daemon/state.ini` and starts in it.
  Without a saved profile, it starts in balanced.
- Every profile set, even to the current profile, makes asusd write that
  profile's power limits and fan curves again. Write a test override after
  the switch.
- An s2idle resume resets the CPU temperature limit in the SMU (the chip's
  power controller) to 95 °C. `oruc-cpu-limits` sets it again after a resume
  through systemd. `rtcwake`, as in `verify-nixos-rog.sh --suspend`, skips
  systemd's sleep hooks, so the unit also checks the limit every 30 s.
- Tctl, the CPU temperature the limit acts on, is `k10temp` `temp1`; `acpitz`
  `temp1` shows the same value.
- The RTX 4070 sleeps only while nothing reads it. A program that shows its
  usage or temperature, such as a ksystemstats sensor or `nvidia-smi`, keeps it
  awake, so the kVitals panel widget shows only the Radeon. KWin and
  nvidia-powerd keep `/dev/nvidia0` open but do not keep it awake.

To measure a profile, or a change to its limits or fan curves before you
commit it, run the thermal test. It heats the laptop and runs the fans hard
for several minutes, and needs the charger plugged in:

```sh
scripts/thermal-test-rog.sh balanced
scripts/thermal-test-rog.sh performance --ppt 35,45,60 --seconds 120 --label perf-35
```

It prints the peak temperature, the clock over the last 40 s of load and the
highest fan speeds. The samples go to `~/.local/state/nixos-config-thermal/`.
On exit it sets the original profile again and restarts asusd and
`oruc-cpu-limits`, which write that profile's own limits and curves.

## Check the running laptop

After a deploy, check the running laptop from fedora-desktop:

```sh
scripts/verify-nixos-rog.sh
```

The script writes a JSON report under `~/.local/state/nixos-config-verify/`.
It exits 1 when a check fails. `--suspend` adds three s2idle cycles. They
darken the screen, so they do not run, and the check fails, while someone uses
the laptop: a local session that is neither idle nor locked. Lock the screen
first, or pass `--while-in-use`.
It also checks that the Plasma panel widgets are installed and that KWin
loaded the effects the config turns on. A Plasma session that started before
the deploy shows as manual, because it keeps the plugins of the old system;
log out and in, then rerun.

## Check a visual change

Glass draws only behind see-through pixels and at window edges, so a shot of a
maximized, opaque window shows none of it. To see the blur, the edge lighting
and the edges of a window, take the screenshot around a Ghostty window, whose
background is see-through:

```sh
scripts/screenshot-nixos-rog.sh --window /tmp/nixos-rog.png
```

The script opens the Ghostty window on the running session, takes the shot and
closes the window. Without `--window` it takes the screen as it is. Crop the
window's edges at full size before you judge them.

Glass's `WindowClasses` list names windows by their resource class or resource
name. To read both for each open window, run:

```sh
scripts/kwin-windows-on-rog.sh
```
