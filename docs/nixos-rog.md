# nixos-rog

- [Hourly updater](#hourly-updater)
- [Failures and notifications](#failures-and-notifications)
- [Secrets](#secrets)
- [DNS](#dns)
- [Claude Code and Codex setup](#claude-code-and-codex-setup)
- [Heavy commands](#heavy-commands)
- [Power and heat](#power-and-heat)
- [Microphone](#microphone)
- [Check the running laptop](#check-the-running-laptop)
- [Check a visual change](#check-a-visual-change)
- [Plasma panels](#plasma-panels)
- [Plasma looks](#plasma-looks)
- [Switch the scheme](#switch-the-scheme)
- [Deskflow](#deskflow)
- [Keyboard keys](#keyboard-keys)
- [Known faults](#known-faults)
- [VS Code settings](#vs-code-settings)
- [Drive VS Code](#drive-vs-code)

Boot entries, generations and the GPU mode are in [recovery.md](recovery.md#nixos-rog).

A date in this guide marks a measurement or a reading of upstream source on that
day. Repeat the measurement before you rely on it.

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
| nixpkgs, dms and sops-nix | They wait up to a day for the cache to hold the packages built from them. See [Cached packages](#cached-packages). |
| kwin-effects-glass, glass-style, hushmic, nixpkgs-spotify, spicetify-nix, tinted-vscode and warm-burnout | Never. Their `flake.nix` URLs pin a commit, so moving one is a hand edit. |

When the new llm-agents revision has a coding agent that cache.numtide.com does
not hold yet, or the run cannot tell, llm-agents stays where it is. So the
laptop does not compile an agent at full load. The next run tries again.

If `main` moves during the build, the host keeps the update. The next run
merges it on top of the new `main`.

A switch leaves the desktop shell, the keyring and other user services on their
old version. `home-manager/README.md` lists them.

`oruc-auto-update.service` reads a fine-grained GitHub token,
`github-update-token`, limited to this repository. The script writes private
Nix and gh config files under the service's runtime directory. Child-process
environments carry only the file paths. systemd removes the directory after
the run. Processes of `oruc` can still read those files; this removes the
token from inherited environments without isolating the service from that user.

To run the updater now, run `upgrade` on nixos-rog. It prints the updater's
log while it runs and exits with the run's status. From fedora-desktop:

```sh
ssh -t nixos-rog upgrade
```

A manual deploy exits 77 while an update holds the deploy lock, and the updater
deploys `main` again on top of a generation you restored. To pause the updater
until the next reboot, run
`sudo systemctl mask --runtime --now oruc-auto-update.timer` on nixos-rog.
[recovery.md](recovery.md#a-generation-the-boot-menu-does-not-list) pauses it
before it restores a generation.

### Cached packages

cache.nixos.org does not hold the packages that come from this flake's own
inputs, overlays or settings. `ci/cached-packages.nix` lists the free ones of
each host: airpods-tui, DankMaterialShell (DMS), Deskflow, the Glass KWin effect and Qt
style, herdr while `pkgs/herdr.nix` builds a newer release than llm-agents,
the sddm-astronaut login theme, the lock screen's video wallpaper plugin and
`sops-install-secrets`, plus the newer libportal that Deskflow links. It reads them from the host's own
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

whisper-cpp is not in the list. `machines/nixos-rog/media.nix` builds it for
the RTX 4070's CUDA architecture (sm_89) only, and neither cache.nixos.org nor
the Cachix cache holds that build. Its closure holds unfree NVIDIA libraries, and
`cachix push` uploads a whole closure, so the public cache must not receive it.
The laptop compiles whisper-cpp itself, each time an update changes its
derivation.

## Failures and notifications

The exit codes below come from `deploy.sh`, except 76. The
[exit-code table in deploy.md](deploy.md#exit-codes) says what each one means.

| Event | What happens | Notification |
| --- | --- | --- |
| GitHub cannot be reached | The run exits quietly. The next run tries again. | None |
| A clone or fetch fails while GitHub answers | It counts as a failure. | Critical |
| The deploy fails with 70, 71, 74 or 79 | The next run tries the same update again. | Critical |
| The deploy fails with another status, or another host no longer evaluates (76) | The run does not try that update again until `main` or an upstream moves. | Critical |
| Any other step of the script fails, such as a Nix evaluation, `git push`, `gh pr merge` or an unset variable | The next run tries again. | Critical, once per run |
| Another deploy holds the lock (77) | The run stops without a failure. The next run tries again. | "Update waiting" from the second run in a row that 77 holds back |
| nixos-rog runs a release whose files `main` lacks (78) | The run stops without a failure. The next run tries again. | "Update waiting" from the first run that 78 holds back |
| The run reaches 2 hours | The service stops the run (`TimeoutStartSec`). | Critical |
| The system shuts down during a run | systemd stops the run. | Critical, when the desktop still shows notifications; the updater waits at most 5 seconds for it |
| The run ends without reporting, such as a kernel kill for memory or a SIGKILL | `oruc-auto-update-died.service` reads the result systemd gives it. | Critical "Update died" with that result |

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

- Omer's shared SSH key, `~/.ssh/id_ed25519_omer`
- the age key derived from the laptop's SSH host key

Edit the file from a checkout on nixos-rog. The shared key has a password, and
sops reads the key file itself, not ssh-agent, so it asks for the password on
the terminal. A run without a terminal fails with `could not read passphrase`.

```sh
SOPS_AGE_SSH_PRIVATE_KEY_FILE=~/.ssh/id_ed25519_omer nix shell nixpkgs#sops -c sops secrets/nixos-rog.yaml
```

### Rotate github-update-token

The token does not expire. Rotate it when it may have leaked. GitHub lists it as
"nixos-rog auto-update". Do the steps in this order, so the laptop keeps a
working token until the new one is deployed:

1. Create the new token on GitHub (Settings, Developer settings, Fine-grained
   tokens). Set the repository access to this repository only, the permissions
   Contents and Pull requests to read and write, and no expiration. When the
   repository moves to a new GitHub repository, edit the token's repository
   access by hand, because a fine-grained token names its repositories.
2. From the repository root of a checkout on nixos-rog, write the token into
   the file without printing it. The command waits for the token on a hidden
   prompt. `jq -R .` turns the token into the JSON string that `sops set`
   expects, and sops reads it from stdin, so it never appears in a process list
   or a file. sops then asks for the shared key's password on the terminal:

   ```sh
   read -rs token && printf '%s' "$token" | jq -R . | SOPS_AGE_SSH_PRIVATE_KEY_FILE=~/.ssh/id_ed25519_omer nix shell nixpkgs#sops -c sops set --value-stdin secrets/nixos-rog.yaml '["github-update-token"]'; unset token
   ```

3. Commit the file and land it, then deploy it with
   `./deploy.sh nixos-rog switch`. [deploy.md](deploy.md) has the rules.
4. Start the updater as in [Hourly updater](#hourly-updater). The new token
   works when the log reaches "Everything is current." or the update deploys.
   When the log shows `git ... failed while GitHub answers`, the new token is
   wrong or lacks access to this repository, and the laptop holds it. Skip
   step 5, because the old token still works on GitHub. Create a corrected token,
   repeat steps 2 to 4 with it, and in step 5 delete both the old token and the
   wrong one.
5. Delete the old token on the same GitHub page.

## DNS

Public names go only to NextDNS over TLS. Tailnet names go to Tailscale's
MagicDNS.

The public names under `risoluto.dev` (`openchamber.risoluto.dev`,
`cliproxy.risoluto.dev`) and `signoz.statuslantern.com` point at Tailscale
addresses. The NextDNS profile's DNS-rebinding protection answers those names
with `0.0.0.0`. So the NextDNS profile's Allowlist in the dashboard holds
`risoluto.dev` and `statuslantern.com`. Each entry also turns off NextDNS
filtering for that one domain.

Without the entries, OpenChamber, cliproxy and SigNoz fail to connect as if the
server were down. The `risoluto-dev-allowlisted` or
`statuslantern-com-allowlisted` check in `scripts/verify-nixos-rog.sh` also
fails.

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
`~/Desktop/workspace/dotfiles`. Every hour, the user timer
`desktop-sync-config.timer` runs that checkout's
`desktop/bin/desktop-sync.sh --config`. Query it with `systemctl --user`. The
script links the rules, skills, hooks and agents. It also syncs Claude Code's
`settings.json` in both directions. The service sets `DESKTOP_SYNC_COMMIT=1`, so
the script also commits the config files it recorded and pushes them to `main`,
only while the checkout is on `main` and equal to `origin/main`.

Home Manager keeps the shell and tools, and adds one entry,
`~/.claude/skills/claude-code-home-manager`, a plugin that gives Claude Code the
`nixos` MCP server from `home-manager/modules/applications.nix`. The same
server list is in `~/.config/mcp/mcp.json`.

The unit does nothing until that checkout exists.

## Heavy commands

`heavy <command> [argument...]` (`machines/nixos-rog/heavy.nix`) runs a heavy
command in one of two slots, at nice 10, in a systemd user scope that the
kernel slows above 10 GiB of memory and stops above 14 GiB or 4 GiB of swap. A
third command waits for a slot. `scripts/lib/rog-copy.sh` runs the Nix calls of
the `*-on-rog.sh` scripts under it. `scripts/affected-hosts.sh`,
`scripts/thermal-test-rog.sh` and `deploy.sh`'s build of the system use it too.
The hourly updater runs outside the slots, so it never makes an agent wait;
its unit's `MemoryHigh` slows it above 10 GiB but never stops it. A repository whose test script follows infra's `heavy` contract, such
as gastrodili's `scripts/heavy.ts`, picks it up from PATH. Run any other Nix
evaluation of this flake on nixos-rog as `heavy nix ...`. The cap covers evaluation only: Nix builds run in
`nix-daemon.service`, outside the scope.

On 2026-10-16, Nix evaluations from several agents at once filled the 30 GiB:
the kernel failed a page allocation, and Claude Code stopped the background
shells of idle sessions. That day `nix flake check` of this flake peaked at
4.9 GiB and nixos-rog's toplevel `drvPath` evaluation at 7.3 GiB, which the
10 GiB and 14 GiB caps leave room for.

## Power and heat

Six services share the laptop's power settings. Each setting has one owner:

| Setting | Set in | Applied by |
|---|---|---|
| power profile, EPP, CPU boost | power-profiles-daemon's own profile rules; `nixosModules/peripherals.nix` only enables it | power-profiles-daemon |
| power limits, NVIDIA limits, fan curves | `machines/nixos-rog/asus.nix`, `machines/nixos-rog/fan-curves.json` | asusd, on each profile change |
| CPU temperature limit, top clock | `machines/nixos-rog/cpu-limits.nix` | `oruc-cpu-limits` |
| power-saver on low battery | `machines/nixos-rog/low-battery.nix` | `oruc-low-battery` |
| battery charge limit (80%) | `machines/nixos-rog/asus.nix` | asusd, when it starts |
| NVIDIA Dynamic Boost | `machines/nixos-rog/graphics.nix` | nvidia-powerd, which asusd runs on AC |
| scheduler power mode | `machines/nixos-rog/configuration.nix` | scx_lavd, fixed at `--performance` |

Edit the fan curve numbers in `machines/nixos-rog/fan-curves.json`. `asus.nix`
only reads that file and hands each curve to asusd.

Facts that matter when you change or measure them:

- `powerprofilesctl set` over SSH needs `sudo`; polkit refuses it otherwise.
- power-profiles-daemon's `power-saver` is asusd's `quiet` profile.
  `thermal-test-rog.sh` takes `power-saver`, `balanced` or `performance`;
  `fan-curves.json` and `asusctl fan-curve` use `quiet`, `balanced` and
  `performance`.
- The profile you pick stays after a reboot, because power-profiles-daemon
  saves it in `/var/lib/power-profiles-daemon/state.ini` and starts in it.
  Without a saved profile, it starts in balanced.
- Every profile set, even to the current profile, makes asusd write that
  profile's power limits and fan curves again. Write a test override after
  the switch.
- An s2idle resume resets the CPU temperature limit in the SMU (the chip's
  power controller) to 95 °C. `oruc-cpu-limits` sets it again after a resume
  through systemd. `rtcwake`, as in `verify-nixos-rog.sh --suspend`, skips
  systemd's sleep hooks, so the unit also checks the limit every 30 s. Each
  check reads the current power profile again, so a missed profile signal
  cannot restore the previous profile's limits.
- Tctl, the CPU temperature the limit acts on, is `k10temp` `temp1`; `acpitz`
  `temp1` shows the same value.
- How the firmware reads a fan curve (the rounding of each point, each fan's
  1 % floor, and the first point's speed below its temperature) is in the
  comment above `fanCurveTable` in `machines/nixos-rog/asus.nix`.
- The fans do not follow Tctl exactly. On 2026-10-13 the MID fan kept turning
  at a Tctl of 47 °C, under its first point (50, 55 or 52 °C in quiet, balanced
  and performance), and stopped at 44 °C. Judge a curve change by the fan speeds
  over a few minutes, not by one sample.
- ROG Control Center shows each curve point as PWM × 100 / 255, rounded down,
  and reads the curves from asusd. `asusctl fan-curve --mod-profile quiet`
  (or `balanced`, `performance`) prints the same curves without the app.
- `nvidia-smi` reports a 105 W power limit whatever asusd sets. It showed 105 W
  with `nv_tgp` at 70 and at 85 in a test; the deployed config uses 55 and 85.
  The limits asusd set are the `current_value` files under
  `/sys/class/firmware-attributes/asus-armoury/attributes/`. On AC
  on 2026-10-13, under the thermal test's `--load gpu`, the RTX 4070 drew
  about 80 W in balanced (`nv_tgp` 55, `nv_dynamic_boost` 5) and about 105 W
  in performance (85 and 20). With 2 CPU threads also loaded, it drew about
  60 W in balanced.

From fedora-desktop, in the repository root, run the thermal test to measure a
profile, or a change to its limits or fan curves before you commit it. It drives
nixos-rog over SSH, heats the laptop and runs the fans hard for several minutes,
and needs the charger plugged in:

```sh
scripts/thermal-test-rog.sh balanced
scripts/thermal-test-rog.sh performance --ppt 35,45,60 --seconds 120 --label perf-35
scripts/thermal-test-rog.sh performance --load gpu --seconds 120 --label gpu-perf
scripts/thermal-test-rog.sh balanced --fans 'CPU=40:0,45:40,50:60,55:80,60:100,65:140,70:180,75:255' --label cpu-fan-try
```

`--fans` takes one group per fan (`CPU`, `GPU` or `MID`) of 8 `TEMP:PWM` points,
and the example shows the CPU group. The override lasts for that run only, so
copy a curve you like into `fan-curves.json`.

The test measures heat, clock and fan speed under full load, on AC, with the
limits of the profile you name. It exits 2 on battery, so it cannot answer a
complaint about balanced mode on battery. The battery limits are `dcTunings` in
`machines/nixos-rog/asus.nix`, and balanced uses EPP `balance_power` on battery
(see [CPU and power profile](#cpu-and-power-profile)). Read the live values over
SSH with `powerprofilesctl get` and the asus-armoury `current_value` files
instead.

It prints the peak temperature, the clock over the last 40 s of load and the
highest CPU and MID fan speeds. The samples file also records the GPU fan.
`--load gpu` runs gpu-burn on the RTX 4070 instead of stress-ng on the CPU, and
`--load both` runs both; the summary then adds the RTX 4070's highest power draw
and temperature. The samples go to `~/.local/state/nixos-config-thermal/`, and
their first line names the script's git blob, so a run cited in a PR can be
matched to its commit. On exit it sets the original profile again and restarts
asusd and `oruc-cpu-limits`, which write that profile's own limits and curves.

The test builds stress-ng and gpu-burn from the release deployed on nixos-rog,
so it needs a prior deploy. It exits 75 when another thermal test runs there.

### CPU and power profile

- power-profiles-daemon 0.30 writes the governor, the energy preference (EPP,
  the CPU's hint for how fast to ramp up) and the `boost` file of every CPU
  policy. power-saver sets `powersave`, EPP `power` and boost off. Balanced sets
  `powersave`, boost on, and EPP `balance_performance` on AC or `balance_power`
  on battery. Performance sets `performance`, EPP `performance` and boost on.
  Source: `src/ppd-driver-amd-pstate.c` at tag 0.30, read 2026-10-13.
- power-profiles-daemon writes the per-policy `policy*/boost` files, and the
  global `cpufreq/boost` stays 1. It rewrites boost on every profile change and
  every switch between AC and battery, so a hand-written boost value does not
  last. `verify-nixos-rog.sh` reads the per-policy files.
- With the `performance` governor, the amd-pstate driver accepts only EPP
  `performance` and answers any other value with `-EBUSY` (upstream
  `drivers/cpufreq/amd-pstate.c`, read 2026-10-12). On the laptop in performance,
  `energy_performance_available_preferences` lists only `performance` (read
  2026-10-13).
- scx_lavd runs in its performance mode in every profile. Its balanced and
  powersave modes use core compaction (packing tasks onto as few cores as the
  load needs), and with `--autopower` the scheduler picked powersave in
  power-saver, where the pointer lagged. On 2026-10-18 in power-saver, a
  bpftrace probe of the wake-to-run delay of KWin's Mesa thread
  (`kwin_wayla:cs0`) over 20 s showed these worst delays:
  `--autopower` 101 ms with 14 delays over one 240 Hz frame (4.2 ms),
  `--balanced` 134 ms with 18, `--performance` 0.9 ms with none, and no
  sched_ext 0.05 ms with none. Mean SoC power (amdgpu `power1_input`, 30 s,
  desktop in use) was 15.0 to 16.9 W with `--autopower`, 13.6 W with
  `--performance` and 13.9 W with no sched_ext.
- Boost stays on in balanced because `oruc-cpu-limits` caps that profile's top
  clock at 4.0 GHz (`machines/nixos-rog/cpu-limits.nix`). Boost off cuts
  all-core speed by about 45 % and one-core speed by about 60 %. In performance
  under full load on 2026-10-10, stress-ng fell from 45 406 to 24 959 operations
  per second on all cores and from 4 567 to 1 806 on one core, while Tctl fell
  from 95 to 67 °C and CPU power from 71 to 36 W. That run used the power
  settings of that day, not today's.
- The same file sets balanced's CPU temperature limit to 80 °C. The balanced fan
  curve is a separate setting in `fan-curves.json`, applied by asusd. Its CPU
  points run from 55 to 94 °C, so the points above 80 °C matter only when Tctl
  passes the limit.
- `amd_pstate/prefcore` reads `disabled` by design. On this Zen 5 chip the
  `amd_hfi` driver ranks the cores instead, and scx_lavd reads that ranking from
  `cpufreq/amd_pstate_prefcore_ranking`. The 8 fast threads (4 Zen 5 cores)
  rank 196 to 208 and the 16 efficient threads (8 Zen 5c cores) rank 125
  (CachyOS 7.2.8 source and laptop, 2026-10-12;
  `amd_hfi` was still bound on 2026-10-13).
- The asus-armoury ranges on the GA605WI, read on AC on 2026-10-13:
  `ppt_pl1_spl` 15 to 80 W, `ppt_pl2_sppt` and `ppt_pl3_fppt` 35 to 80 W,
  `nv_tgp` 55 to 85 W, `nv_dynamic_boost` 5 to 20 W and `nv_temp_target` 75 to
  87 °C.

### RTX 4070 sleep

- The RTX 4070 sleeps only while nothing reads it. A program that shows its
  usage or temperature, such as a ksystemstats sensor or `nvidia-smi`, keeps it
  awake, so the kVitals panel widget shows only the Radeon. KWin, niri and
  nvidia-powerd keep `/dev/nvidia0` open but do not keep it awake.
- A running `nvidia-smi dmon` under ksystemstats means some client still
  holds an RTX 4070 sensor. After a login on 2026-10-13 it kept running with
  no client, because ksystemstats kept sensors that a client had subscribed
  to twice, or had subscribed to as it left. `overlays/ksystemstats.nix`
  patches both.
- To see whether it sleeps, read
  `/sys/bus/pci/devices/0000:65:00.0/power/runtime_status` once a second. It
  reads `suspended`, `resuming` or `active`. Never poll with `nvidia-smi`, which
  wakes the card. The Radeon is `0000:66:00.0`.
- On battery, the firmware sends the driver a power-limit notice (NVPCF) on
  every 1 % charge drop, which woke the sleeping card for 20 to 22 s. Measured
  2026-10-11 on driver 615.78.08, BIOS 316, idle on battery: 4 of 4 drops from
  100 to 96 % woke it with the stock driver, and 0 of 4 with the two patches of
  [NVIDIA pull request 1299](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1299)
  that `machines/nixos-rog/graphics.nix` applies. Repeat the count after a
  driver update. The comment in `graphics.nix` says when to drop the patches.
- The patches do not cover unplugging the charger or switching the platform
  profile. Each still wakes the card once. In a 25-minute patched run on
  2026-10-12, those two wakes kept it awake for 44 s.
- The power cost of a wake is below about 5 W, the swing of the battery reading
  around one drop (19.6, 21.3 and 24.2 W before, during and after a wake).
  Measure idle draw from the charge difference over a whole run instead. On
  2026-10-11 the charge fell 0.208 Ah in 21
  minutes on battery, which is about 10 W. The real figure lies between 9 and 11
  W, because the battery reports charge in coarse steps.

## Microphone

Apps that record from the default source get HushMic's denoised internal
microphone, "HushMic". HushMic, from `machines/nixos-rog/hushmic.nix`, runs
Ceva's DPDFNet model on the raw microphone. `mic-default-source.service`, in
`machines/nixos-rog/media.nix`, makes that source the default and sets the
microphone level after every HushMic start. While HushMic is not running,
WirePlumber falls back to an earlier default source it remembers, such as
"Easy Effects Source", or else to the raw microphone. While HushMic runs, a
WirePlumber hook in `media.nix` turns any choice of the raw microphone as the
default into "HushMic", so pick another source, or stop `hushmic.service`, to
record the raw microphone by default. An app that names the raw
microphone in its own settings skips the denoising; set it to the default
source or to "HushMic".

EasyEffects offers a second denoised source, "Easy Effects Source", made with
DeepFilterNet from `machines/nixos-rog/easyeffects.nix`. It also reads the raw
microphone, so pick one of the two sources in an app, never both. In the
2026-10-13 A/B take, HushMic cut silence and typing by 73 to 75 dB and
DeepFilterNet by 5 to 8 dB, and both kept speech within 1 dB.

EasyEffects' bypass switch resets to off at each start of
`easyeffects.service`, and the unit starts again after a quit from the tray or
the window. Leave bypass off. EasyEffects unlinks its input pipeline 10 s after
the last app stops recording, and with bypass on it does not link it again, so
the next app that records gets silence. Run `easyeffects -b 2` to turn bypass
off. EasyEffects has no output effects, so apps play to the speakers directly.

From fedora-desktop, in the repository root, compare the microphone level or the
two denoisers. Someone at the laptop follows the prompts:

```sh
scripts/mic-ab-on-rog.sh level 0.3 0.5 0.7
scripts/mic-ab-on-rog.sh ab
```

## Check the running laptop

After a deploy, check the running laptop from fedora-desktop:

```sh
scripts/verify-nixos-rog.sh
```

The script writes a JSON report under `~/.local/state/nixos-config-verify/` and
exits 1 when a check fails. It switches the laptop to each power profile in
turn, checks that the CPU limits, fan curves and asus-armoury limits there match
the deployed config, then sets the original profile again. It also checks that
the Plasma panel widgets are installed and that KWin loaded the effects the
config turns on. A Plasma session that started before the deploy shows as
manual, because it keeps the plugins of the old system; log out and in, then
rerun.

`--suspend` adds three s2idle cycles. They darken the screen, so they do not
run, and the check fails, while someone uses the laptop (a local session that is
neither idle nor locked). Lock the screen first, or pass `--while-in-use`.

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
window's edges at full size before you judge them, with `--crop WxH+X+Y` in
the screen's pixels.

Text contrast in Ghostty depends on what shows through the blur, and a white
window behind it is the worst case. Before you judge a change to Ghostty's
opacity or colors, or to a terminal app's theme, ask Omer to put a white
window where the Ghostty window opens.

Glass's `WindowClasses` list is a blacklist. A window it names gets no blur,
and each entry must match the window's resource class or resource name exactly.
To read both for each open window in the Plasma session, run:

```sh
scripts/kwin-windows-on-rog.sh
```

## Plasma panels

plasma-manager builds the panels from `home-manager/modules/plasma-panels.nix`:
a floating top bar of three islands and the dock for the glass look, or a top
bar and the dock for the klassy look. In the floating bar, Panel Colorizer draws
each run of widgets that panel spacers separate on one background, so one
colorizer styles the whole bar. The dock's launchers are `oruc.plasma.dockLaunchers` in
`home-manager/modules/plasma-looks/default.nix`. The dock's task manager and
the glass look's launcher come from the macOS Tahoe theme (the `mac-tahoe`
flake input). The task manager is Plasma's own with notification badges and
hover zoom, whose `dockMagnification` key is a percentage from 100 to 150
(default 110). Whenever the layout changes, plasma-manager deletes `plasma-org.kde.plasma.desktop-appletsrc` at the next login and builds
the panels again. A panel or widget change made in Plasma's settings window
lasts only until then, so write a lasting change in the Nix file.

- Every 5 minutes in a Plasma session, `oled-care.timer`
  (`machines/nixos-rog/oled-care.nix`) moves each panel by 2 px, up to 8 px,
  to spare the OLED panel. The top bar grows in height, which resizes
  maximized windows by the same amount, and the dock moves sideways.
  `mac-tahoe-oled-care status` prints each panel's base geometry and the
  current shift. To keep the panels at their base until the next login, run
  `systemctl --user stop oled-care.timer`, then `mac-tahoe-oled-care restore`.
  The `oled-care-timer` check of `scripts/verify-nixos-rog.sh` fails while the
  timer is stopped.
- A shift that fails can leave a guard file. While it exists, every later
  shift does nothing and `oled-care.service` still succeeds. Then
  `mac-tahoe-oled-care status` prints `recovery pending` and exits 1, and the
  `oled-care-state` check of `scripts/verify-nixos-rog.sh` fails.
  `mac-tahoe-oled-care restore` clears the guard. When `restore` cannot reach
  plasmashell or times out waiting for the lock, run it again in the Plasma
  session, because it keeps what it needs to put each panel back. When it
  fails otherwise, stop the timer and delete `oled-care.disabled` and `oled-care-transition.json` in
  `~/.local/state/mac-tahoe-liquid-kde/`. When its error was `uncertain
  geometry has no persisted panel bases`, no panel moved. After any other
  error, a panel may sit a few pixels off, and `scripts/panels-rebuild-on-rog.sh`
  puts it back at its size in the Nix file; that rebuild also drops panel
  changes made in Plasma's settings, so ask Omer first. Then start the timer.
- Panel Colorizer draws the blurred backgrounds. Its blur area can stay stale in
  the running session. On the night of 2026-10-12 to 2026-10-13, after a live
  change of the dock's height and style, the blur covered only part of the dock,
  and toggling edit mode did not refresh it. Judge a panel change after a new login.
- A logout can show a black screen with a cursor for about a minute. On
  2026-10-13 plasmashell did not quit, and systemd killed it at its stop
  timeout. The cause is not confirmed.
- To build the panels from the Nix file as the next login would, without a
  logout, deploy and then run `scripts/panels-rebuild-on-rog.sh`. It backs up
  the panel files, restarts ksystemstats and plasmashell in login order, runs
  plasma-manager's panel script and prints the RTX 4070's power state. Then run
  `scripts/verify-nixos-rog.sh`.
- To try a panel setting before you write it into the Nix file, run a script in
  the running plasmashell. A script's `writeConfig` reaches the panel file, but
  kVitals and Panel Colorizer read it only when plasmashell starts, so restart
  it with `systemctl --user restart plasma-plasmashell` to see the setting.
  First copy `~/.config/plasma-org.kde.plasma.desktop-appletsrc`
  and `~/.config/plasmashellrc` to a backup directory, such as
  `~/.local/state/dock-try`, so you can put them back:

  ```sh
  ssh nixos-rog 'export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus WAYLAND_DISPLAY=wayland-0; qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "print(panels().length)"'
  ```

- KWin reads an effect's `kwinrc` settings only when it loads the effect. A
  deploy reloads Glass only (`home.activation.reloadGlass` in
  `home-manager/modules/plasma-looks/glass.nix`). After a change to another effect,
  call `reconfigureEffect` in the Plasma session, as that activation does:
  `busctl --user call org.kde.KWin /Effects org.kde.kwin.Effects reconfigureEffect s <name>`.
- Glass settings are the `Effect-blurplus` keys in `plasma-looks/glass.nix`.
  Ghostty's opacity and blur are `programs.ghostty.settings` in
  `home-manager/modules/applications.nix`, and its colors are in `theme.nix`.
  The Glass look sets its own opacity and padding in `plasma-looks/glass.nix`.
  To read Glass's option names at the revision `flake.lock` pins, run this in
  the repository root:

  ```sh
  rev=$(jq -r '.nodes["kwin-effects-glass"].locked.rev' flake.lock)
  gh api "repos/4v3ngR/kwin-effects-glass/contents/src/blur.kcfg?ref=$rev" --jq .content | base64 -d
  ```

Prove a panel or effect change with `scripts/screenshot-nixos-rog.sh` before and
after it. For a change to the top bar, `--crop 2560x60+0+0` keeps only the
top 60 pixels, so the shot leaves out the windows below them.
[Check a visual change](#check-a-visual-change) says how to see the blur.

## Plasma looks

A Plasma look is the Plasma style, window decoration, Qt style, color scheme
and KWin blur that belong together. Each look is a file in
`home-manager/modules/plasma-looks/`, and `plasmaLookNames` in
`machines/selectors.nix` lists them. `theme.plasmaLook` in the machine record
names the default look. The looks are:

- `glass`: the Glass decoration, Qt style and blur with the translucent Base16
  scheme, square corners and a floating top bar of three islands. The left
  island holds the macOS Tahoe theme's launcher and the active app, the
  middle one the clock, and the right one the song with a play/pause button
  while Spotify or Brave has a song loaded, then the system monitor, tray and
  show-desktop button.

  While Glass is the active look, Ghostty gets the opacity (0.66) and
  padding (12 x 10 px) of the iglass Frosted theme in every session,
  niri included.
- `klassy`: Klassy's decoration, Qt style and Plasma style with the opaque
  Base16 scheme. Klassy's settings app changes its buttons and title bars.

To try another look without a rebuild, run this in the Plasma session on
nixos-rog, then log out and in:

```sh
plasma-look            # prints the active look and the others
plasma-look klassy
```

The color scheme, the panels, the Plasma style and the KWin effects load at
the next login. A live color scheme change can crash Electron apps such as
Discord, so neither `plasma-look` nor a deploy changes it.
The choice lasts across deploys and reboots, because the Home Manager service
(`home-manager-oruc.service`) runs `theme --reapply` after it activates the
default look and scheme. When that step fails, the look can be half applied, and
`journalctl -u home-manager-oruc` shows the error; run `plasma-look <look>`
again. That failure does not fail the unit, because a failed unit makes the
deploy roll back the whole system.
`plasma-look glass` goes back to the default look.

Settings made in a look's own settings app, such as Klassy's, last until that
app changes them, because no look writes them.

To add a look:

1. Add its name, in lowercase letters and digits, to `plasmaLookNames` and create
   `home-manager/modules/plasma-looks/<name>.nix`, following `klassy.nix`. It
   sets `oruc.plasma.colorScheme`, `oruc.plasma.widgetStyle`, the Plasma style
   and the window decoration while it is active. A unit of the look that
   changes colors or styles runs once per login with
   `plasma-looks/once-per-login.nix`, because Home Manager starts it again at
   every switch.
2. Install its packages whenever Plasma runs, not only while the look is
   active. A look other than the default is a Home Manager specialisation, and
   a specialisation cannot install packages on this setup; the evaluation
   fails when it tries.
3. Write each KWin plugin switch the look owns as false while another look is
   active, because plasma-manager never removes a key that a look leaves out. The evaluation
   fails while two looks write different `kwinrc` Plugins switches, and the
   error names the missing ones.

`scripts/verify-nixos-rog.sh` checks the widgets, KWin effects and panels of
the stored look.


## Switch the scheme

`theme` switches the Base16 scheme of the Home Manager apps without a rebuild,
on both hosts. It offers the record's `theme.scheme` and the schemes in
`theme.schemes` (`machines/inventory.nix`):

```sh
theme                      # prints the active scheme and the others
theme gruvbox-dark-medium
```

Ghostty (which `theme` tells to reload its config) and new Neovim windows take
the new colors at once, and so does Claude Code on nixos-rog, where the dotfiles
`settings.json` selects `custom:scheme`. The wallpaper of a scheme without a
file in `assets/wallpapers` is the default one recolored to that scheme
([Theme](architecture.md#theme)). On Plasma, `oruc-plasma-wallpaper` sets it
again at each activation, so the desktop wallpaper changes with the scheme. VS Code takes its theme extension and
its window background at its next start, and the Markdown viewer takes the
scheme the next time a file opens. GTK 4 and libadwaita apps (Mission Center,
for example) read their colors file when they start, so a running one may keep
the old colors until it restarts. That file is
`~/.config/gtk-4.0/oruc-colors.css` on nixos-rog and `gtk.css` on
nixos-latitude. The KDE colors
and the Plasma splash load at the next login, as with `plasma-look`. The login
screen, the boot menu, the console, niri and the keyboard's Aura color keep the
record's scheme. So does
Spotify, because Spicetify builds its colors into the package, which a variant
cannot replace. The login form assumes a dark record scheme, because it draws
the form at 30 % opacity over the dark Jake video, where a light scheme's dark
text loses contrast. Starship reads its colors at each prompt, so it changes in
open shells too. [Theme](architecture.md#theme) lists the apps that keep fixed
colors. The choice lasts across
deploys and reboots, and `theme <record's scheme>` goes back. Because each
deploy and boot activates the record's scheme before the stored one, apps that
follow the scheme show the record's colors for a moment then.

To offer another scheme, add its name to `theme.schemes`. A name from the
tinted-theming collection needs nothing else; a scheme it lacks goes in
`assets/schemes` ([architecture.md](architecture.md#theme)).

## Deskflow

Deskflow shares one keyboard, mouse and clipboard between the two machines.
fedora-desktop is the server and nixos-rog is the client. They connect over
Tailscale.

On nixos-rog:

- The `app-org.deskflow.deskflow` user service in `machines/nixos-rog/home.nix`
  starts the client at a Plasma login only. Its name carries Deskflow's app ID,
  so Plasma's remote control notice names Deskflow instead of "An
  unidentifiable application". A Wayland client types through the remote desktop
  portal, which Plasma has and niri does not. The service exits 5 when another
  Deskflow already runs, such as a copy that Plasma's autostart or the menu
  started. The unit treats 5 as success and does not restart.
- The unit sets `RefuseManualStart`, so a deploy never starts a client you
  quit and never restarts a running one. `systemctl --user start app-org.deskflow.deskflow`
  fails for the same reason; open Deskflow from the menu instead.
- `overlays/deskflow.nix` builds Deskflow against libportal 0.10.0 or newer.
  With an older libportal, Deskflow builds without clipboard code and the laptop
  never sends what you copy. The overlay's install check fails the build in that
  case.
- Home Manager sets only `log.toFile` in `~/.config/Deskflow/Deskflow.conf`,
  because Deskflow rewrites that file. The server address and the TLS keys in it
  stay as you set them in the Deskflow window. Both machines write
  `~/deskflow.log`.

On fedora-desktop, outside this repository:

- The server is the upstream RPM, installed with `dnf install`, at the version of
  the laptop's client, because Fedora's package can lag the release.
  `rpm -q deskflow` on fedora-desktop prints the server's version, and
  `scripts/eval-on-rog.sh --json '.#nixosConfigurations.nixos-rog.pkgs.deskflow.version'`
  prints the laptop's.
- TLS is on, and the server requires client certificates. Keep the Network IP
  setting automatic, because a fixed Tailscale address would stop the server
  whenever Tailscale is not up yet.
- The server's screen for the laptop must be named exactly `nixos-rog`.
  Deskflow 1.27 ignores a second alias for a screen, and the server then logs
  `unrecognised client name "nixos-rog"`. When the laptop boots Windows, set the
  Windows client's computer name to `nixos-rog` as well.
- Do not press Regenerate certificate. It changes the server's fingerprint, and
  the laptop refuses the server until you accept the new one there. A
  fingerprint prompt on the laptop that you did not cause is suspicious, so
  decline it.

After a deploy that changes Deskflow, the running client stays on the old build
until you quit it and open it from the menu, or log in again. The new client
may make Plasma ask on the laptop to allow remote control with clipboard
access. Approve it with the laptop's own keyboard or touchpad.

To check the clipboard, move the cursor onto the laptop and copy there. Then
look for `computer "nixos-rog" updated clipboard 0` in `~/deskflow.log` on
fedora-desktop. Deskflow sends the laptop's clipboard only after the cursor has
been on the laptop, so a `wl-copy` over SSH while the cursor is on fedora-desktop
proves nothing.

## Keyboard keys

Fn lock is on, so the function row sends plain F1 to F12 and its special keys
need Fn. Fn+Esc toggles Fn lock. This table comes from `libinput debug-events`
on 2026-10-09, in the niri sessions:

| Keys | Sends | Effect |
| --- | --- | --- |
| Fn+F1 | `KEY_MUTE` | mute |
| Fn+F4 | `KEY_PROG3` (`XF86Launch3`) | next Aura effect; niri binds it in `machines/nixos-rog/asus.nix` and Plasma in `machines/nixos-rog/home.nix` |
| Fn+F5 | `KEY_PROG4` (`XF86Launch4`) | cycles the power profile in the niri shells and in Plasma |
| Fn+F6 | `Meta+Shift+S` | screenshot in niri; the laptop has no Print key |
| Fn+F7, Fn+F8 | `KEY_BRIGHTNESSDOWN`, `KEY_BRIGHTNESSUP` | brightness |
| Fn+F9 | `Meta+P` | Plasma's display switch; niri does not bind it |
| Fn+F10 | `KEY_F21` | nothing in this repository binds it |
| Fn+F11 | `KEY_SLEEP` | suspends the laptop |
| Fn+Left, Right, Up, Down | `Home`, `End`, `Page Up`, `Page Down` | navigation, not keyboard lighting |

Fn+F2, Fn+F3 and Fn+F12 sent nothing in that log.

`wev` cannot show a key that niri binds, because niri takes it before any window
sees it. To read the keycodes of every key, run this in a terminal on the
laptop. It asks for the sudo password:

```sh
sudo nix run nixpkgs#libinput -- debug-events --show-keycodes
```

## Known faults

- The MT7925 Bluetooth controller needs linux-firmware 20260916 or newer. Older
  firmware leaves `bluetoothctl list` empty and logs
  `hci0: Execution of wmt command timed out` after a restart from CachyOS. Keep
  the nixpkgs input at or above that release.
- asusd logs `Failed to set pwm3_enable to 1: No such device` at start. It does
  not change the fans, because `verify-nixos-rog.sh` compares every fan's curve,
  MID included, and passes with the message in the log.

## VS Code settings

`oruc.vscodeSettings` holds the VS Code settings this repository owns.
`home-manager/modules/vscode.nix` declares it and sets most keys, and
`home-manager/modules/theme.nix` adds the theme keys. Each switch writes them into
`~/.config/Code/User/settings.json` over the values there and lists them in
`settingsSync.ignoredSettings`, so Settings Sync keeps them off Omer's other
machines. An assertion in the same file fails evaluation when a setting reaches
the file any other way. Every other key in `settings.json` is Omer's. It
survives each switch, and Settings Sync uploads it.

- Add a setting that every host needs to `oruc.vscodeSettings`.
- When Omer asks why VS Code behaves a certain way, name the key that causes it
  and wait for his answer before you write a key outside `oruc.vscodeSettings`,
  because Settings Sync copies that key to his other machines.
- `settings.json` is a writable file. When a switch cannot parse it, such as
  after a hand edit that is not JSON5, the switch warns and keeps the file, and
  the declared settings apply at the next switch after it parses.
- A key removed from `oruc.vscodeSettings` stays in `settings.json` but leaves
  the ignore list, so Settings Sync uploads it. Delete it from the file too.
- The editor and terminal fonts come from Ghostty's `font-family` setting.

## Drive VS Code

nixos-rog is Omer's daily laptop. Before you click in VS Code, take a
screenshot with `scripts/screenshot-nixos-rog.sh`. When he is working in VS
Code, tell him what to click, or ask him to close it.

`scripts/vscode-cdp-on-rog.sh` drives VS Code from fedora-desktop over the
Chrome DevTools Protocol. `on` refuses while VS Code runs, because a stop
signal raises its quit dialogs and a forced stop loses the open window. Once
Omer has closed it, `on` starts VS Code with a debugging port on the laptop's
loopback and tunnels the port to `127.0.0.1:19229`:

```sh
scripts/vscode-cdp-on-rog.sh on
scripts/vscode-cdp-on-rog.sh run '[{"key":"F1"},{"text":"Help: About"},{"key":"Enter"},{"sleep":500},{"eval":"document.querySelector(\".monaco-dialog-box\")?.innerText"},{"key":"Escape"}]'
scripts/vscode-cdp-on-rog.sh run '[{"shot":"/tmp/vscode.png"}]'
scripts/vscode-cdp-on-rog.sh off
```

`run` runs the steps with Node on fedora-desktop, which needs the built-in
`fetch` and `WebSocket` globals; `node -e 'console.log(typeof WebSocket)'`
prints `function` when Node has them. It takes a JSON list of steps and prints
one JSON line for each:

| Step | What it does |
| --- | --- |
| `{"eval": "JS"}` | evaluates the expression in the window and prints its value |
| `{"key": "F1"}` | presses `F1`, `Enter`, `Escape`, `Tab`, `End`, `Home`, `ArrowUp` or `ArrowDown` |
| `{"text": "..."}` | types the text into the focused field |
| `{"click": [x, y]}` | clicks at window coordinates in CSS pixels |
| `{"shot": "FILE"}` | saves a PNG of the window |
| `{"sleep": 500}` | waits the given milliseconds |

`off` closes the tunnel. VS Code keeps its debugging port until Omer quits it.

- `browser-harness` cannot drive VS Code: Electron answers its first browser
  command with `Not supported`. Use `run`.
- `window.dialogStyle` is `custom` in `home-manager/modules/vscode.nix`, so
  VS Code draws its dialogs inside the window, where `eval` and `click` reach
  them. File pickers stay native, outside the window.
- When Settings Sync is turned on and finds a conflict, it waits on its
  "Conflicts Detected" dialog. Resolve the conflict through that dialog's
  "Show Conflicts" button; a conflict resolved from the side bar leaves the
  dialog waiting and Sync stays in "Turning on...".
