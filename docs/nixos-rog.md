# nixos-rog

- [Updater](#updater)
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

## Updater

Every host installs the newest `main` with NixOS's
`system.autoUpgrade` (`nixosModules/auto-upgrade.nix`, turned on by
`oruc.autoUpgrade.enable`). `nixos-upgrade.timer` starts `nixos-upgrade.service`
every hour, with up to 10 minutes of random delay, and `Persistent=true` runs a
missed hour soon after boot. Before each run, `scripts/upgrade-condition.sh`
fetches `main` into `/var/lib/nixos-upgrade/repo.git` over git, which needs no
GitHub token, and the service then runs
`nixos-rebuild switch --refresh --flake git+file:///var/lib/nixos-upgrade/repo.git`,
which builds this host's system from that `main` and switches to it. It never
reboots a PC; devbox reboots at night for a new kernel
([Deploy to a server](deploy.md#deploy-to-a-server)). It has none of `deploy.sh`'s rollback timer, session check or SSH
check. On devbox, which reboots for a new kernel, the service runs
`nixos-rebuild boot` first and switches only when the kernel stays the same.
A successful run whose running system is the boot default writes the system
and the commit to
`/var/lib/nixos-upgrade/installed`, which `scripts/lib/running-revision.sh`
reads, so `scripts/affected-hosts.sh --running` can tell a host that is behind.
`flake.lock` on `main` moves every 2 hours
([Update inputs, apps and the kernel](updates.md)), so a new upstream release
reaches the host within about 3 hours. The run stops after 3 hours
(`TimeoutStartSec`), and its `MemoryHigh` slows it above 12 GiB.

The service skips a run, without a failure, when:

- the host is on battery (`ConditionACPower`);
- `deploy.sh` holds the deploy lock, or a deploy's `deploy-rollback.timer` is
  pending;
- `/boot` is not mounted, or has less than 1 GiB free;
- fetching `main` fails, such as while GitHub cannot be reached;
- the host runs a `test` deploy, a deploy from a dirty tree, or a commit that
  `main` lacks, such as a branch deployed for a proof, so the hour does not
  undo it;
- installing this `main` failed before; the next `main` runs again;
- MemAvailable is below 10 GiB, because an evaluation of `main` took 6.9 GiB
  (journal, 2026-10-23) and two at once filled swap on 2026-10-31.

`deploy.sh` exits 77 while the service runs, so the two never switch at once.

To install `main` now, run `upgrade` on the host (`nixosModules/upgrade.nix`,
a command every host has). It starts `nixos-upgrade.service`, prints its log
while it runs and exits with the run's status, or 1 when the run skipped. Its
run ignores the last three skip reasons above. From nixos-desktop:

```sh
ssh -t nixos-rog upgrade
```

A switch leaves the desktop shell, the keyring and other user services on their
old version. `home-manager/README.md` lists them.

The service installs `main` again on top of a generation you restored. To pause
it on the host until the next reboot:

```sh
sudo mkdir -p /run/systemd/system.control
sudo ln -sfn /dev/null /run/systemd/system.control/nixos-upgrade.timer
sudo systemctl daemon-reload
sudo systemctl stop nixos-upgrade.timer
```

Use a mask, not a stop. An activation can restart a timer that was only
stopped. `systemctl mask --runtime` does not work here: it writes the mask to
`/run/systemd/system`, which systemd reads after `/etc/systemd/system`, where
NixOS keeps the unit (`systemctl show -p UnitPath`). The mask in
`/run/systemd/system.control` comes first, so
`systemctl show -p LoadState nixos-upgrade.timer` prints
`LoadState=masked`. The mask does not stop a run that is already going. Run
`systemctl is-active nixos-upgrade.service` and wait until it prints
`inactive` or `failed` before you restore a generation or deploy by hand. To
resume before the next reboot, run
`sudo rm /run/systemd/system.control/nixos-upgrade.timer`,
`sudo systemctl daemon-reload` and then
`sudo systemctl start nixos-upgrade.timer`. After a reboot the timer runs
again, so pause it again after each reboot. [recovery.md](recovery.md#nixos-rog)
uses this pause when it pins a generation.

### Packages no cache holds

cache.nixos.org does not hold the packages that come from this flake's own
inputs, overlays or settings, such as airpods-tui, DankMaterialShell (DMS),
Deskflow, the Glass KWin effect and Qt style, linctl, the sddm-astronaut login
theme and the lock screen's video wallpaper plugin. Each host compiles them
itself when an update changes them. It also compiles the modules it builds
against the CachyOS kernel ([The kernel](updates.md#the-kernel)).

whisper-cpp is one of them. `machines/nixos-rog/media.nix` builds it for the
RTX 4070's CUDA architecture (sm_89) only, so the laptop compiles it each time
an update changes its derivation.

## Failures and notifications

A run that fails, such as a build that fails on this host, leaves the host on
the system it runs. `nixos-upgrade-failed.service` records that `main` in
`/var/lib/nixos-upgrade/failed`, so the hourly runs skip it until `main` moves,
and shows a critical "Update failed" popup through systembus-notify, which
`nixosModules/monitoring.nix` turns on. The first `error:` line is in
`journalctl -u nixos-upgrade`. `upgrade` tries that `main` again.

## Secrets

`secrets/nixos-rog.yaml` holds the NextDNS profile ID (`nextdns-profile`).
sops encrypts the file for two recipients, which `.sops.yaml` lists:

- Omer's shared SSH key, `~/.ssh/id_ed25519_omer`
- the age key derived from the laptop's SSH host key

Edit the file from a checkout on nixos-rog. The shared key has a password, and
sops reads the key file itself, not ssh-agent, so it asks for the password on
the terminal. A run without a terminal fails with `could not read passphrase`.

```sh
SOPS_AGE_SSH_PRIVATE_KEY_FILE=~/.ssh/id_ed25519_omer nix shell nixpkgs#sops -c sops secrets/nixos-rog.yaml
```

After an edit, run `scripts/check-secrets.sh` on nixos-rog; for
`secrets/nixos-desktop.yaml`, run it on nixos-desktop. It decrypts the file
with the host key, as the host does at boot, and fails when a secret the
configuration declares has no key in the file or the file holds a key no secret
declares. It prints key names only.

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

A Wi-Fi sign-in page (hotel, cafe) often blocks DNS-over-TLS until you log in.
When it does not load, switch to the network's own plain DNS until you are
logged in. `captive-dns on` (`nixosModules/nextdns.nix`) adds a drop-in under
`/run/systemd/resolved.conf.d/` that sorts after `nextdns.conf`, clears the
NextDNS servers and uses the network's own DNS in plain text. The first command
switches, and the second removes the drop-in and switches back:

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

`home-manager/modules/claude-tools.nix`, which `desktop-sync.nix` imports,
installs the `claude-tools` command of `pkgs/claude-tools` (its README describes
it) and the `claude` shell function. Its `claude-tools-usage.timer` runs
`claude-tools usage` every 10 minutes while the checkout's
`desktop/claude-code/accounts.json` exists. It writes each Claude Code
account's usage limits and login state to `~/.cache/claude-tools/usage.json`,
and reads the files of devbox and nixos-desktop over SSH. nixos-desktop's
everyday SSH key has a passphrase that no timer can type, so it reads this
host's file with a key of its own. `machines/nixos-rog/claude-tools-usage-read.nix`
allows that key only to print the file: its entry in `authorized_keys` forces
`cat .cache/claude-tools/usage.json` and sets `restrict`, which turns off the
terminal and every forwarding. The account list and the shared preferences stay in
the private checkout, because this repository is public.
The Claude accounts widget in the top bar shows that file.
`oruc.plasma.claudeAccountsWidget` installs it from
`pkgs/claude-accounts-widget.nix` and puts it on the panel. Its Log in button
opens a Ghostty window that runs `claude-tools accounts login`. plasmashell keeps the
widget code it loaded, so a switch that installs a new widget package restarts
`plasma-plasmashell` once (`restartPlasmashellOnWidget` in
`home-manager/modules/plasma-panels.nix`), and the panels flicker.

`home-manager/modules/agent-cli.nix` installs worktrunk (`wt`) on nixos-desktop,
nixos-rog and devbox, with the worktree layout that the dotfiles `worktrees`
skill gives every agent: `~/Desktop/workspace/worktrees/<repo>/<branch>`, with
each `/` in the branch name turned into `-`. A new worktree runs
`direnv allow` and loads its devenv shell, so the devenv git hooks exist before
the first commit. Removing one stops its `devenv up`. Its
`worktree-sweep.timer` runs `wt step prune` once a day in each repository under
`~/Desktop/workspace`. The prune removes each worktree and branch that is
merged into the default branch, has no uncommitted changes and is older than a
day. The sweep lists the worktrees it kept in
`/tmp/agents/worktree-sweep/report.md` and in its log. A failed prune fails the
unit, so `systemctl --user --failed` shows it; read
`journalctl --user -u worktree-sweep`.

`nixosModules/codex-hooks.nix` writes `/etc/codex/hooks.json`, Codex's system
hook layer. Codex runs a system hook without the trust prompt that a hook in
`~/.codex/hooks.json` needs. The hook sends each `apply_patch` to the dotfiles
`guard-main-edit.py`, which refuses an edit in a repository's main checkout, as
it does for Claude Code. A user without that file in `~/.claude/hooks` edits
freely.

## Heavy commands

`heavy <command> [argument...]` (`home-manager/modules/heavy.nix`, on nixos-rog
and nixos-desktop) runs a heavy command at nice 10, in a systemd user scope
that the kernel slows above 10 GiB of memory and stops above 14 GiB or 4 GiB of
swap. Commands never wait for each other. A `heavy` inside another one runs its
command directly. One reached over SSH, as in `scripts/run-unit-on-rog.sh` from
nixos-desktop, gets a scope of its own on nixos-rog.
`scripts/lib/work-copy.sh` runs the Nix calls of `scripts/eval.sh`,
`scripts/build.sh`, `scripts/check.sh` and `scripts/run-unit-on-rog.sh` under
it. `scripts/affected-hosts.sh`, `scripts/thermal-test-rog.sh`, `deploy.sh`'s
build of the system and the checks of the git hooks (`devenv.nix`) use it too.
`nixos-upgrade.service` runs outside heavy; its `MemoryHigh` slows it above
12 GiB (`nixosModules/auto-upgrade.nix`) but never stops it.

`heavy` follows the contract of infra's `heavy` on devbox. It exports
`HEAVY_ACTIVE=1`, and a repository script that finds `heavy` on PATH while
`HEAVY_ACTIVE` and `CI` are unset runs its suite through it, such as
gastrodili's `scripts/heavy.ts`. Run any other Nix evaluation of this flake as `heavy nix ...` on the host you work on, never over
SSH on the other one: on 2026-10-27 agents on nixos-desktop filled nixos-rog's
memory that way. The cap covers evaluation only: Nix builds run in
`nix-daemon.service`, outside the scope.

On 2026-10-16, Nix evaluations from several agents at once filled the 30 GiB:
the kernel failed a page allocation, and Claude Code stopped the background
shells of idle sessions.

On 2026-10-24, measurements under `heavy` used each scope's `memory.peak`.
With the combined `nix flake check`, `ci/checks.sh` peaked at 10.0 GiB.
`MemoryHigh` held it there, with 181 `high` events in `memory.events` and about
0.4 GB of swap in `memory.swap.peak`. With one evaluation per host,
`ci/checks.sh` peaked at 8.5 GiB. `ci/unit-cycles.sh` peaked at 4.9 GiB with one
host at a time. `devenv test` peaked at 8.8 GiB.

`ci/checks.sh` checks each host's derivation type and
`drvPath` in a separate process, so the evaluator releases its heap between
hosts. `nix fmt` checks the formatter; the output gate rejects new output kinds
or formatter systems until their coverage is added. `ci/unit-cycles.sh` also
evaluates hosts one at a time. Adding a host therefore does not keep another
host's evaluator heap in either check. The limits in
`home-manager/modules/heavy.nix` stay unchanged.

## Power and heat

Seven services share the laptop's power settings. Each setting has one owner:

| Setting | Set in | Applied by |
|---|---|---|
| power profile, EPP, CPU boost | power-profiles-daemon's own profile rules; `nixosModules/peripherals.nix` only enables it | power-profiles-daemon |
| power limits, NVIDIA limits, fan curves | `machines/nixos-rog/asus.nix`, `machines/nixos-rog/fan-curves.json` | asusd, on each profile change |
| CPU temperature limit, top clock | `machines/nixos-rog/cpu-limits.nix` | `oruc-cpu-limits` |
| power profile picked in ROG Control Center or `asusctl profile set` | `machines/nixos-rog/profile-sync.nix` | `oruc-profile-sync`, which sets it in power-profiles-daemon |
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
  Without a saved profile, it starts in balanced. So the running profile is the
  one a reboot brings back, and the `ppd-profile-kept` check of
  `scripts/verify-nixos-rog.sh` compares the saved and the running profile.
- Every profile set, even to the current profile, makes asusd write that
  profile's power limits and fan curves again. Write a test override after
  the switch. In asusd's journal, the rewrite ended 75 ms after a profile set,
  and `thermal-test-rog.sh` waits 4 s before it writes its overrides.
- Nothing but `oruc-cpu-limits` sets a profile's CPU temperature limit or top
  clock. The unit writes both at start, after each power-profiles-daemon profile
  change, after a resume, and when the charger is plugged in or out.
- The CPU temperature limit lives in the SMU (the chip's power controller) and
  is lost at reboot. `oruc-cpu-limits` writes it with ryzenadj through
  `ryzen_smu` (`machines/nixos-rog/apps.nix`). It survives a profile switch and
  an asusd restart, but an s2idle resume resets it to 95 °C, and the unit sets it
  again after a resume through systemd. `rtcwake`, as in
  `verify-nixos-rog.sh --suspend`, skips systemd's sleep hooks and runs no
  resume command, so the unit also checks both limits every 30 s. Each check
  reads the current power profile again, so a missed profile signal cannot
  restore the previous profile's limits.
- Each profile's limits in `machines/nixos-rog/cpu-limits.nix` are 70 °C in
  power-saver, 80 °C with a 4.0 GHz top clock in balanced and 85 °C in
  performance. Power-saver and performance keep each core's own top clock.
- Tctl, the CPU temperature the limit acts on, is `k10temp` `temp1`; `acpitz`
  `temp1` shows the same value.
- The firmware takes the power limits in `machines/nixos-rog/asus.nix` only
  while every fan follows a custom curve. `fan-curves.json` maps each profile
  (quiet, balanced, performance) and each fan (CPU, GPU, MID) to 8 points of
  (°C, PWM 0 to 255). Neither value falls from left to right, and the `curveOk`
  assertion in `asus.nix` fails the evaluation when a curve breaks that rule,
  has another point count or leaves out a fan. The kernel sends each point as
  100 × PWM / 255 percent, rounded down. In a sweep on 2026-10-13 every fan
  started from stop at 1 % (PWM 3), and PWM 0 to 2 send 0 %, which stops the
  fan. The firmware also runs each fan at its first point's speed below that
  point's temperature. So the CPU and GPU fans start at PWM 3 and never stop.
  The MID fan starts at 0 and stops when cool, because at 1 % it turns at 3400
  to 4300 rpm, against about 2200 for the others. The CPU curve ends at 82 °C
  with PWM 104 in quiet, at 94 °C with 165 in balanced and at 86 °C with 200 in
  performance.
- asusd writes the asus-armoury limits and the fan curves of the platform
  profile on each profile change, and the firmware applies the `ppt_*` limits;
  `ryzenadj -i` shows them as its STAPM and PPT limits. The kernel keeps the
  curve it last sent to the firmware in the `asus_custom_fan_curve` hwmon, where
  `pwmN_enable` reads 1 while it applies. asus-wmi numbers the fans `pwm1` to
  `pwm3` as CPU, GPU and MID. `scripts/verify-nixos-rog.sh` switches to each
  profile and compares these files with the deployed config.
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

From nixos-desktop, in the repository root, run the thermal test to measure a
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
so it needs a prior deploy. It builds gpu-burn only for the RTX 4070's CUDA
architecture (sm_89), as `media.nix` does for whisper-cpp. It exits 75 when another thermal test runs there.

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
- scx_lavd runs in its performance mode in every profile
  (`services.scx` in `machines/nixos-rog/configuration.nix`). Its balanced and
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
  clock at 4.0 GHz (`machines/nixos-rog/cpu-limits.nix`). One busy thread at
  5.1 GHz held the CPU at 74 °C and spun the fans up. At 4.0 GHz it stayed at
  56 °C with the fans at their floor. Power-saver needs no clock cap, because
  power-profiles-daemon turns boost off there. Boost off cuts
  all-core speed by about 45 % and one-core speed by about 60 %. In performance
  under full load on 2026-10-10, stress-ng fell from 45 406 to 24 959 operations
  per second on all cores and from 4 567 to 1 806 on one core, while Tctl fell
  from 95 to 67 °C and CPU power from 71 to 36 W. That run used the power
  settings of that day, not today's.
- The Zen 5c cores stop at 3.29 GHz, below any clock cap in `cpu-limits.nix`, so
  a cap changes only the Zen 5 cores.
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
  87 °C. Each value in `acTunings` and `dcTunings` (`machines/nixos-rog/asus.nix`)
  stays inside the GA605W range of the kernel's asus-armoury table. On battery
  the only GPU limit is the temperature target. Quiet takes each range's minimum
  and performance each GPU range's maximum; the other values trade speed for
  heat and fan noise. In a 4-minute all-thread stress-ng run on AC, the CPU
  peaked at 62 °C in quiet (boost off), 75 °C in balanced and 81 °C in
  performance. The fan curves' first points changed after that run, so rerun it
  with `scripts/thermal-test-rog.sh`. `cpu-limits.nix` caps each profile's CPU
  temperature.
- asusd writes `/sys/firmware/acpi/platform_profile` itself when you switch in
  ROG Control Center or with `asusctl profile set`. power-profiles-daemon
  missed that write: it kept its old profile, governor and EPP, and
  `oruc-cpu-limits` kept the old profile's limits. The daemon watches the file's
  directory inside its own sysfs mount, and that watch never fired.
  `oruc-profile-sync` (`machines/nixos-rog/profile-sync.nix`) watches the file
  itself in the host's mount and sets the profile in the daemon. When the daemon
  sets a profile, it writes the file before it answers D-Bus calls, so the unit
  then reads the same profile and sets nothing.

### RTX 4070 sleep

- The RTX 4070 sleeps only while nothing reads it. A program that shows its
  usage or temperature, such as a ksystemstats sensor or `nvidia-smi`, keeps it
  awake, so the kVitals panel widget shows only the Radeon (`gpuSelection` is
  `gpu1` in `home-manager/modules/plasma-panels.nix`). ksystemstats numbers GPUs
  in PCI address order. On nixos-rog, the only hybrid machine, the RTX 4070
  (`0000:65:00.0`) comes first, so `gpu1` is the Radeon 890M. KWin, niri and
  nvidia-powerd keep `/dev/nvidia0` open but do not keep it awake. A display
  on a connector it drives, such as its HDMI port, keeps it awake, and the `dgpu-runtime-suspended` check of
  `scripts/verify-nixos-rog.sh` then expects it active.
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
  that `patchesOpen` in `machines/nixos-rog/nvidia-driver.nix` lists, which
  `machines/nixos-rog/graphics.nix` imports. Both commits are kept in
  `machines/nixos-rog/nvidia-patches/`, so a rewritten pull request cannot break
  a rebuild.
  Repeat the count after a driver update, and drop the patches when a driver
  release includes that pull request.
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
Ceva's DPDFNet model on the raw microphone, not on EasyEffects' source, so no
audio is denoised twice. `mic-default-source.service`, in
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

From nixos-desktop, in the repository root, compare the microphone level or the
two denoisers. Someone at the laptop follows the prompts:

```sh
scripts/mic-ab-on-rog.sh level 0.3 0.5 0.7
scripts/mic-ab-on-rog.sh ab
```

`micVolume` in `machines/nixos-rog/media.nix` is 0.25, the `wpctl` volume that
`mic-default-source.service` sets for the internal microphone. At 1.0 the codec
adds 60 dB (Capture +30 dB and Internal Mic Boost +30 dB), and speech clips. On
2026-10-13, `scripts/mic-ab-on-rog.sh` found that speech clipped 36726 samples
at 0.45 and peaked at -3.2 dBFS at 0.3. At 0.25 the 60 s A/B take peaked at
-5.2 dBFS with no clipped samples.

## Check the running laptop

After a deploy, check the running laptop from nixos-desktop:

```sh
scripts/verify-nixos-rog.sh
```

The script writes a JSON report under `~/.local/state/nixos-config-verify/` and
exits 1 when a check fails. It switches the laptop to each power profile in
turn, checks that the CPU limits, fan curves and asus-armoury limits there match
the deployed config, then sets the original profile again. It also checks that
the Plasma panel widgets are installed and that KWin loaded the effects the
config turns on. A running Plasma session keeps the plugins it loaded at login,
so a deploy or a `plasma-look` that drops or adds one shows only after the next
login. The `plasma-session` check shows as manual while plasmashell started
before the current system or the last `plasma-look`; log out and in, then
rerun. The `oled-care-state` check fails while a failed OLED shift has left a
guard that stops every later shift, until `oled-care.service` restores the
panels ([Plasma panels](#plasma-panels)).

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
window behind it is the worst case. The default `background-opacity` is 0.9
(`home-manager/modules/applications.nix`). At 0.65, a white window behind turned
the background mid-gray, and the text fell to 3:1 contrast. At 0.90, the base04
gray keeps 5:1. The Glass look sets 0.66, and its contrast over a white window
is not measured. Before you judge a change to Ghostty's
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
`machines/nixos-rog/home.nix`. The dock's task manager and
the glass look's launcher come from the macOS Tahoe theme (the `mac-tahoe`
flake input). The task manager is Plasma's own with notification badges and
hover zoom, whose `dockMagnification` key is a percentage from 100 to 150
(default 110). Whenever the layout changes, plasma-manager deletes `plasma-org.kde.plasma.desktop-appletsrc` at the next login and builds
the panels again. A panel or widget change made in Plasma's settings window
lasts only until then, so write a lasting change in the Nix file.
On nixos-desktop and nixos-rog, `oruc.plasma.claudeAccountsWidget` adds the
Claude accounts widget before kVitals in either top bar ([Claude Code and Codex
setup](#claude-code-and-codex-setup)).

- Every 5 minutes in a Plasma session, `oled-care.timer`
  (`machines/nixos-rog/oled-care.nix`) moves each panel by 2 px, up to 8 px,
  to spare the OLED panel. The top bar grows in height, which resizes
  maximized windows by the same amount, and the dock moves sideways.
  `mac-tahoe-oled-care status` prints each panel's base geometry and the
  current shift. To keep the panels at their base until the next login, run
  `systemctl --user stop oled-care.timer`, then `mac-tahoe-oled-care restore`.
  The `oled-care-timer` check of `scripts/verify-nixos-rog.sh` fails while the
  timer is stopped.
- A shift that fails can leave a guard file. While it exists, a shift does
  nothing and exits 0, and `mac-tahoe-oled-care status` prints `recovery
  pending` and exits 1. The next timer run then runs
  `mac-tahoe-oled-care restore`, which puts the panels back and clears the
  guard, before it shifts. When `restore` fails, `oled-care.service` fails on
  each run and the `oled-care-state` check of `scripts/verify-nixos-rog.sh`
  fails. A `restore` that cannot reach plasmashell or times out waiting for
  the lock keeps what it needs to put each panel back, so a later run can
  still succeed. When it fails otherwise, stop the timer and delete `oled-care.disabled` and `oled-care-transition.json` in
  `~/.local/state/mac-tahoe-liquid-kde/`. When its error was `uncertain
  geometry has no persisted panel bases`, no panel moved. After any other
  error, a panel may sit a few pixels off, and `scripts/panels-rebuild-on-rog.sh`
  puts it back at its size in the Nix file; that rebuild also drops panel
  changes made in Plasma's settings, so ask Omer first. Then start the timer.
- Panel Colorizer draws the blurred backgrounds. Its blur area can stay stale in
  the running session. On the night of 2026-10-12 to 2026-10-13, after a live
  change of the dock's height and style, the blur covered only part of the dock,
  and toggling edit mode did not refresh it. Judge a panel change after a new login.
- The floating top bar of the glass look has a widget spacing of 0, and Panel
  Colorizer gives that spacing to the panel's layout outside edit mode. Plasma's
  panel then loops forever when something is dragged between two widgets. On
  2026-10-28 plasmashell's main thread used a whole core and answered no D-Bus
  call for 25 s, so Spectacle could not take a screenshot; `systemctl --user
  restart plasma-plasmashell` ended it. `overlays/plasma-desktop.nix` patches
  the loop. Drop the overlay only when the bar's spacing is above 0, or once
  Plasma's `containments/panel/LayoutManager.js` steps at least one pixel.
- The title bar widget (`titleBar` in `home-manager/modules/plasma-panels.nix`)
  shows the active window's app icon and name. The widget's default leaves 10 px
  after the name. The top bar ends the title with a spacer, so it leaves none. In
  the floating bar's left island, a margin of 6 plus the island's end margin
  leaves as much space after the name as before the launcher icon (16 px each in
  a screenshot of nixos-rog).
- In the floating bar, the title bar fills the panel's height (36 px, read
  through plasmashell scripting) and the other widgets keep 4 px free above and
  below (28 px), so the vertical margins (4 px top and bottom) give every
  background the same height. With spacing 0 and side margins, the backgrounds
  of an island meet without a seam and leave 6 px inside each end.
- A logout can show a black screen with a cursor for about a minute. On
  2026-10-13 plasmashell did not quit, and systemd killed it at its stop
  timeout. The cause is not confirmed.
- To build the panels from the Nix file as the next login would, without a
  logout, deploy and then run `scripts/panels-rebuild-on-rog.sh`. It backs up
  the panel files, restarts ksystemstats and plasmashell in login order, runs
  plasma-manager's panel script and prints the RTX 4070's power state. At a
  login ksystemstats starts before plasmashell. Repeated ksystemstats restarts
  under a running plasmashell left kVitals without updates on 2026-10-13. The
  script deletes plasma-manager's last-run record for the panel script so that
  it runs again, and waits up to 20 s for plasmashell's scripting interface
  first. Then run
  `scripts/verify-nixos-rog.sh`.
- To try a panel setting before you write it into the Nix file, run a script in
  the running plasmashell. A script's `writeConfig` reaches the panel file, but
  kVitals and Panel Colorizer read it only when plasmashell starts, so restart
  it with `systemctl --user restart plasma-plasmashell` to see the setting.
  First copy `~/.config/plasma-org.kde.plasma.desktop-appletsrc`
  and `~/.config/plasmashellrc` to a backup directory, such as
  `~/.local/state/dock-try`, so you can put them back:

  ```sh
  ssh nixos-rog 'export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus; qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "print(panels().length)"'
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
names the default look. Every other look is a Home Manager specialisation of the
same generation (`machines/variants.nix`), which `plasma-look`
(`nixosModules/hm-variants.nix`) activates without a rebuild. A look writes its
keys only while it is active. The looks are:

- `glass`: the Glass decoration, Qt style and blur with the translucent Base16
  scheme, square corners and a floating top bar of three islands. The left
  island holds the macOS Tahoe theme's launcher and the active app, the
  middle one the clock, and the right one the song with a play/pause button
  while Spotify or Brave has a song loaded, then the system monitor, tray and
  show-desktop button. Its Plasma style, `oruc-glass`
  (`pkgs/oruc-glass-plasma-theme.nix`), is Breeze with see-through popups. Breeze
  fills the background of menus, popups, notifications and KRunner with the
  window color at 85% opacity. This style fills it at 50%, the opacity of the top
  bar's widgets, so the Glass blur shows through. Plasma takes every element the
  style leaves out from Breeze, and the build fails when Breeze's dialog
  background no longer has a fill at 85%.

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
Discord, so neither `plasma-look` nor a deploy changes it; only
[`theme`](#switch-the-scheme) does.
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
   `home-manager/modules/plasma-looks/<name>.nix`, following `klassy.nix`. Add
   its KDE colour scheme, `OrucBase16` or `OrucBase16Glass`, and its Plasma
   style to `looks` in `plasma-looks/default.nix`. The file sets
   `oruc.plasma.widgetStyle` and the window decoration while it is active. A
   unit of the look that changes colors or styles runs once per login with
   `plasma-looks/once-per-login.nix`, because Home Manager starts it again at
   every switch.
2. Install its packages whenever Plasma runs, not only while the look is
   active, so each look installs its packages while any look is active. A look
   other than the default is a Home Manager specialisation, and a
   specialisation cannot install packages on this setup
   (`home-manager/modules/variants.nix`); the evaluation fails when it tries.
3. Write each KWin plugin switch the look owns as false while another look is
   active, because plasma-manager never removes a key that a look leaves out.
   `nixosModules/plasma-looks.nix` fails the evaluation while two looks write
   different `kwinrc` Plugins switches, and the error names the missing ones.

`scripts/verify-nixos-rog.sh` checks the widgets, KWin effects and panels of
the stored look.


## Switch the scheme

`theme` switches the Base16 scheme without a rebuild, on every workstation. It
takes any scheme of the theme pack, which holds all 362 of tinted-theming and
`assets/schemes` ([Theme](architecture.md#theme)):

```sh
theme                      # prints the active scheme and the record's
theme --list               # prints every scheme of the pack
theme tokyo-night-dark
```

Ghostty, running tmux servers and running Neovim, which `theme` tells to
reload, take the new colors at once, and so does Claude Code, whose dotfiles
`settings.json` selects `custom:scheme`. Starship reads its colors at each
prompt, so it changes in open shells too; fzf and atuin take them at their next
start, and the Markdown viewer the next time a file opens. A running VS Code
takes the new colors at once and its see-through window background at its
next start. Its text, button text, muted text such as descriptions and line
numbers, and comments reach 4.5:1 contrast on the editor background in every
scheme, and on the side bar too where the scheme allows it
([Theme](architecture.md#theme)). In niri, the focus ring and borders change at
once, and so do Noctalia and DMS, which `theme` tells to reload and to switch
to the scheme's dark or light mode; `theme` also selects the scheme's palette
in Noctalia when another palette was picked there. rofi and vicinae take the
colors at their next open, wlogout and mpv at their next start, and the Plasma
splash at the next login. kVitals in the Plasma panel draws its text, warning
and critical values in the KDE colors, so it changes with them.

On Plasma, the KDE colors of running apps, GTK 4 and libadwaita apps such as
Mission Center, the cursor, the icons and the Glass glow change at once
([Theme](architecture.md#theme)). A live color scheme change can crash an
Electron app such as Discord; start it again. GTK 3 apps and Kate's editor
colors change at their next start. On nixos-latitude, which has no Plasma, the
GTK colors and the KDE colors and icon theme in `~/.config/kdeglobals` follow
the scheme at each app's next start. niri's cursor follows the scheme's dark or
light variant, while the GTK cursor, the GTK icons and the GTK theme name
follow only the record's scheme and the schemes in `theme.schemes`.

The other apps that follow the scheme take it from a Home Manager variant, so
they follow only the record's scheme and the schemes in `theme.schemes`
(`machines/inventory.nix`); for any other scheme they keep the record's. The
wallpaper of a scheme without a file in `assets/wallpapers` is the default one
recolored to that scheme ([Theme](architecture.md#theme)). On Plasma,
`oruc-plasma-wallpaper` sets it again at each activation, so the desktop
wallpaper changes with the scheme.

The login screen, the boot menu, the console and the keyboard's Aura color
keep the record's scheme. So does Spotify, because Spicetify builds its colors
into the package, which a variant cannot replace. The login form assumes a dark
record scheme, because it draws the form at 30 % opacity over the dark Jake
video, where a light scheme's dark text loses contrast.
[Theme](architecture.md#theme) lists the apps that keep fixed colors. The choice
lasts across deploys and reboots, and `theme <record's scheme>` goes back.
Because each deploy and boot activates the record's scheme before the stored
one, apps that follow a variant show the record's colors for a moment then.

`scripts/check-theme.sh SCHEME...` switches to each scheme, checks the colour
files and a tmux server and two Neovim instances it starts, and switches back.
In a running Plasma session it also checks the KDE colors, the dark or light
set and the Glass glow. It checks VS Code's `settings.json` after each switch,
and `--contrast` also checks the text contrast of every scheme's VS Code theme.
`--host nixos-latitude` runs it there.

To give a scheme the apps that follow a variant, add its name to
`theme.schemes`. A scheme that tinted-theming lacks goes in `assets/schemes`
([architecture.md](architecture.md#theme)).

## Deskflow

Deskflow shares one keyboard, mouse and clipboard between the two machines.
nixos-desktop is the server and nixos-rog is the client. They connect over
Tailscale, and both run the same Deskflow build from this flake.

On nixos-rog:

- The `app-org.deskflow.deskflow` user service in `machines/nixos-rog/home.nix`
  starts the client at a Plasma login only. Its name carries Deskflow's app ID,
  so Plasma's remote control notice names Deskflow instead of "An
  unidentifiable application". A Wayland client types through the remote desktop
  portal, which Plasma has and niri does not. The service exits 5 when another
  Deskflow already runs, such as a copy that Plasma's autostart or the menu
  started. The unit treats 5 as success and does not restart, because a restart
  would only raise that instance's window again.
- The unit sets `RefuseManualStart` and `RefuseManualStop`, so a deploy never
  starts a client you quit and never stops a running one. With
  `RefuseManualStart` alone, Home Manager's switch (sd-switch) stops a changed
  client and cannot start it again. If the cursor is on the laptop at that
  moment, the server keeps nixos-desktop's keyboard and mouse captured for a
  client that is gone. A login and a logout still start and stop the client,
  because the target's `Wants` and `PartOf` are not manual.
  `systemctl --user start` and `stop app-org.deskflow.deskflow` fail for the
  same reason; open Deskflow from the menu, and quit it from its window.
- `overlays/deskflow.nix` builds Deskflow against libportal 0.10.0 or newer.
  With an older libportal, Deskflow builds without clipboard code and the laptop
  never sends what you copy. The overlay's install check fails the build in that
  case.
  The overlay also runs Deskflow's unit tests one at a time, because
  `LoggerTests` and `ComputerTests` rewrite the same `tmp/test/Deskflow.conf`
  and fail when they run in parallel.
- Home Manager sets only `log.toFile` in `~/.config/Deskflow/Deskflow.conf`,
  because Deskflow rewrites that file. The server address and the TLS keys in it
  stay as you set them in the Deskflow window. Both machines write
  `~/deskflow.log`.

On nixos-desktop:

- The `app-org.deskflow.deskflow` user service in
  `machines/nixos-desktop/home.nix` starts the server at a Plasma login, with
  the same `RefuseManualStart`, `RefuseManualStop` and exit 5 rules as the
  client. Deskflow on Wayland reads the keyboard and mouse through the input
  capture portal, so the server starts at a Plasma login, and the unit name
  gives the portal the app ID, as on nixos-rog.
- Home Manager writes the server mode, the screen links file (`deskflowLayout`
  in `machines/nixos-desktop/home.nix`, which puts nixos-rog left of
  nixos-desktop's screen), the log setting and one `[computer_<name>]` group for
  each machine into `Deskflow.conf`.
  Deskflow 1.27 reads the computers from those groups and skips a `screens`
  section in the links file, so a computer missing there stops the server with
  `unknown computer name`.
- TLS is on, and each side checks the other's certificate. The server's
  `~/.config/Deskflow/tls/trusted-clients` holds the laptop's fingerprint, and
  the laptop's `tls/trusted-servers` holds the server's. Each line is
  `v2:sha256:` and the lowercase hex that
  `openssl x509 -in ~/.config/Deskflow/tls/deskflow.pem -noout -fingerprint -sha256`
  prints on the other machine, without colons. Keep the Network IP
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
nixos-desktop. Deskflow sends the laptop's clipboard only after the cursor has
been on the laptop, so a `wl-copy` over SSH while the cursor is on nixos-desktop
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
`home-manager/modules/theme.nix` adds the terminal's contrast key. Each switch
writes them into `~/.config/Code/User/settings.json` over the values there and
lists them in `settingsSync.ignoredSettings`, so Settings Sync keeps them off
Omer's other machines. An assertion in `vscode.nix` fails evaluation when a
setting reaches the file any other way. The color keys `workbench.colorTheme`,
`window.systemColorTheme` and `workbench.colorCustomizations` come from the
stored scheme instead: each switch and each `theme` run merge them from
`~/.config/oruc/vscode-colors.json`, and the ignore list holds them too. Every
other key in `settings.json` is Omer's. It
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

`scripts/vscode-cdp-on-rog.sh` drives VS Code from nixos-desktop over the
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

`run` runs the steps with the local Node, which needs the built-in
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

- `window.dialogStyle` is `custom` in `home-manager/modules/vscode.nix`, so
  VS Code draws its dialogs inside the window, where `eval` and `click` reach
  them. File pickers stay native, outside the window.
- When Settings Sync is turned on and finds a conflict, it waits on its
  "Conflicts Detected" dialog. Resolve the conflict through that dialog's
  "Show Conflicts" button; a conflict resolved from the side bar leaves the
  dialog waiting and Sync stays in "Turning on...".
