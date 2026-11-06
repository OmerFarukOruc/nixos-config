# Workstations

- [Updater](#updater)
- [Failures and notifications](#failures-and-notifications)
- [Heavy commands](#heavy-commands)
- [Switch the scheme](#switch-the-scheme)
- [Gaming](#gaming)

These procedures hold for more than one PC, and each section names the hosts it
covers. Facts that hold only for the laptop are in [nixos-rog.md](nixos-rog.md).

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
- `deploy.sh` holds the deploy lock, a deploy's `deploy-rollback.timer` is
  pending, or its activation or boot entry install still runs, which outlives
  a dropped deploy connection and its lock;
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
again, so pause it again after each reboot. Every rollback recipe in
[recovery.md](recovery.md) uses this pause.

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

A desktop app keeps running the store path it started from, so an update that
a switch installs reaches it only after the app restarts.
`home-manager/modules/stale-apps.nix` starts the `stale-apps` user service at
every Home Manager activation. It looks at the apps that have a `.desktop` file
in the user profile, and names each one whose running process uses a store
path that an earlier system generation's user profile held and the current one
no longer holds, in one "Restart to use the update" popup. That store path is
the process's executable, or for a process of `bash` or `electron`, a store
path in its arguments, as in `electron /nix/store/<app>/…/app.asar`. It names an old version once:
`~/.local/state/stale-apps/notified` lists the store paths it already named,
and each run rewrites that list with the old versions still running.
`journalctl --user -u stale-apps` shows its runs.

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

On 2026-11-01, the same measurement gave 5.31 GiB for `ci/checks.sh` and
2.58 GiB for `ci/unit-cycles.sh` with one host at a time, and 7.85 GiB and
3.68 GiB with two at a time, with no `high` or `max` event in either.

`ci/checks.sh` checks each host's derivation type and
`drvPath` in a separate process, so the evaluator releases its heap when the
host is done. `nix fmt` checks the formatter; the output gate rejects new
output kinds or formatter systems until their coverage is added. Both checks
run two host evaluations at a time (`PARALLEL_EACH_JOBS` in
`scripts/lib/parallel-each.sh`), so a new host adds one evaluator heap only while
it runs, and at most two heaps share the scope's `MemoryHigh`. The limits in
`home-manager/modules/heavy.nix` stay unchanged. `prepare-update.sh inputs`
evaluates the hosts the same way when inputs moved.

The `update` workflow sets `PARALLEL_EACH_JOBS` to 3 in
`.github/workflows/update.yml`, because its runner has no `heavy` scope. On
2026-11-02 the runner had 4 CPUs and 15 GiB as `free -g` shows it. In probe
run 41540059527, a `ci/update.sh` run that moved three inputs on a warm store
took 11.9 min with 3 evaluations at a time and peaked at 11.7 GiB used,
against 14.2 min and 9.2 GiB with 2; on a cold store it peaked at 12.5 GiB.
With 4 at a time, a cold run in probe run 41535294049 peaked at 14.3 GiB and
evaluated the hosts no faster than with 3.

Before the parallel evaluations start, both checks fetch every flake input in
one process (`fetch_inputs` in `scripts/lib/host-systems.sh`), and so do
`prepare-update.sh inputs` and `scripts/affected-hosts.sh`, the latter for
each commit without a stored result. On
2026-11-01 a push failed with `getting Git object ...: object not found` after
two host evaluations each unpacked the same new input into Nix's Git cache.
Three runs that evaluated two hosts with that input missing from the store did
not reproduce it, so the cause is not confirmed, and the single fetch only
keeps the parallel evaluations from fetching.

## Switch the scheme

`theme` switches the Base16 scheme without a rebuild, on every workstation. It
takes any scheme of the theme pack, which holds every tinted-theming and
`assets/schemes` scheme ([Theme](architecture.md#theme)):

```sh
theme                      # prints the active scheme, the record's, the console and login screen scheme, and any failed apply
theme --list               # prints the slug of every scheme in the pack, one per line
theme tokyo-night-dark
```

`theme --help` lists when each app takes the new scheme: at once, at its next
start or open, or at the next login or boot. It is the one list, so this
section holds only what the help text leaves out.

Claude Code follows the scheme because its dotfiles `settings.json`
selects `custom:scheme`, and its status line reads the pack's `statusline`
fact at its next refresh. Every segment's text reaches 4.5:1 on its background
in every scheme. The usage bars take the scheme's green, yellow and red, each
lightened or darkened only as far as 4.5:1 needs. VS Code's text, button text,
muted text such as descriptions and line numbers, and comments reach 4.5:1
contrast on the editor background in every scheme, and on the side bar too
where the scheme allows it ([Theme](architecture.md#theme)). `theme` tells
Noctalia and DMS to switch to the scheme's dark or light mode, and selects the
scheme's palette in Noctalia when another palette was picked there. kVitals in
the Plasma panel draws its text, warning and critical values in the KDE
colors, so it changes with them.

A live color scheme change can crash an Electron app; start it again. On
nixos-latitude, which has no Plasma, the GTK colors and the KDE colors and icon
theme in `~/.config/kdeglobals` follow the scheme at each app's next start. In
a niri session, niri's cursor and the dark or light preference in dconf follow
the scheme at once.

A scheme without a file in `assets/wallpapers` gets the default wallpaper
recolored to it, rendered the first time `theme` selects the scheme
([Theme](architecture.md#theme)).

The console, the login screen and the Limine boot menu keep the scheme after a
reboot. A light scheme leaves the login screen on the record's colors, because
it draws the form at 30 % opacity over the dark Jake video, where a light
scheme's dark text loses contrast. The keyboard's Aura light on nixos-rog and
the case lights on nixos-desktop do not follow the scheme. The keyboard shows
the record's color, and the case lights show the `openrgb-boot` profile. `Fn+F4`
picks another Aura effect, and asusd saves it. The effect stays until a switch
restarts asusd or the laptop reboots, because a switch or a boot restores the
record's Aura file and asusd reads it when it starts.
Telegram follows once it has loaded the palette: open Telegram's Settings, type
`loadcolors` with no text field focused, and pick
`~/.config/oruc/oruc.tdesktop-palette`; it then repaints at each switch.
[Theme](architecture.md#theme) lists the apps that keep fixed colors. The choice
lasts across deploys and reboots, and `theme <record's scheme>` goes back.
On a host without Plasma, each deploy and boot writes the record's GTK
settings to dconf until `theme --reapply` runs the reloads a moment later.

`scripts/check-theme.sh SCHEME...` switches to each scheme, checks the colour
files and a tmux server and two Neovim instances it starts, and switches back.
In a running Plasma session it also checks the KDE colors, the dark or light
set and the Glass glow. It checks VS Code's `settings.json` after each switch,
and `--contrast` also checks, in every scheme, the text contrast of the VS Code
theme, the Claude Code status line, the KDE colours, and the text each app
draws on an accent. The `theme-contrast` flake check runs the same contrast
checks on the built pack before each push.
`--host nixos-latitude` runs it there.

A scheme that tinted-theming lacks goes in `assets/schemes`
([architecture.md](architecture.md#theme)).

## Gaming

`features.gaming` turns this on for nixos-desktop and nixos-rog
(`nixosModules/gaming.nix`, `machines/<host>/gaming.nix`,
`home-manager/modules/gaming.nix`).

- Steam offers GE-Proton (`proton-ge-bin` from nixpkgs), Proton-CachyOS
  (`pkgs/proton-cachyos.nix`) and Proton-Wineland (`pkgs/proton-wineland.nix`)
  besides Valve's own Proton. All three carry the wine.inf fix in
  `pkgs/proton-tarball/reapply-wine-inf.py`, which applies a new release's
  `wine.inf` to a prefix an older release made; nixpkgs lacks it
  (NixOS/nixpkgs#581490). The update workflow moves the two local packages
  ([Apps](updates.md#apps)).
- Proton uses ntsync once the `ntsync` module has made `/dev/ntsync`.
- The login limit `nice -8` lets wineserver raise game threads.
- nixos-desktop's Steam sets `PROTON_FSR4_UPGRADE=1`, which upgrades FSR 3.1
  games to FSR 4 on the RX 7900 XTX, and `MANGOHUD=1`. gamescope is installed
  without `capSysNice`, which breaks it inside Steam (NixOS/nixpkgs#351516).
- nixos-rog's Steam runs Vulkan on the Radeon
  (`VK_LOADER_DRIVERS_SELECT=*radeon*`), so the RTX 4070 sleeps, and sets
  `MANGOHUD=1`. `game-nvidia %command%` runs a game on the RTX with
  `PROTON_DLSS_UPGRADE=1` and the HUD pinned to the RTX. A game started on AC
  holds the Performance profile until it exits, also when AC is unplugged
  meanwhile.

### Launch options

Type these in a game's Steam properties. None of them suits a game with
anti-cheat or an online game; those stay on Valve's Proton without options.

| Option | Use |
| --- | --- |
| `game-nvidia %command%` | nixos-rog, a game for the RTX 4070 |
| `PROTON_FSR4_INDICATOR=1 %command%` | the FSR 4 watermark, to see that the upgrade works |
| `PROTON_USE_OPTISCALER=1 %command%` | GE-Proton, Proton-CachyOS or Wineland, an offline game that offers DLSS 2+, FSR 2+ or XeSS |
| `ENABLE_LAYER_MESA_ANTI_LAG=1 %command%` | nixos-desktop, a game with Anti-Lag 2 |
| `PROTON_DXVK_LOWLATENCY=1 %command%` | Proton-CachyOS or Wineland, a DirectX 9 to 11 game without frame generation |
| `PROTON_VKD3D_LOWLATENCY=1 %command%` | Proton-CachyOS, a DirectX 12 game without frame generation |
| `MANGOHUD=0 gamescope --mangoapp -w <width> -h <height> -f -F fsr -- %command%` | nixos-desktop, the game at a lower size scaled up with FSR 1 |

The FSR 4 and DLSS options download the DLL at a game's first start; the
version follows the manifest that GE-Proton's README names.

### MangoHud

`home-manager/modules/gaming.nix` writes `~/.config/MangoHud/MangoHud.conf` from
a theme renderer (colors, font, position, the preset order and, on nixos-rog,
`pci_dev` of the Radeon), and `~/.config/MangoHud/presets.conf` with the rows of
each layout. On nixos-rog, `game-nvidia` points MangoHud at
`MangoHud-nvidia.conf`, the same file with the RTX's `pci_dev`, through
`MANGOHUD_CONFIGFILE`, and at `presets-nvidia.conf` through
`MANGOHUD_PRESETSFILE`. On nixos-rog the layouts leave out the rows MangoHud
0.8.4 drew as 0 or nonsense on both laptop GPUs: junction and memory
temperature, fan, voltage and power limit (the RTX showed a fan of 1024%). They
also leave out CPU power on the Radeon, where it read 0.0 W, while the RTX
layouts keep it. nixos-desktop's RX 7900 XTX shows every row.
`MANGOHUD_CONFIG=read_cfg` would draw every preset row twice in MangoHud 0.8.4,
and that variable splits a PCI address at its colons.

The HUD starts on full detail; Right Shift+F10 moves to the panel layout, then
the compact one. Rows live only in `presets.conf`, because MangoHud applies
`MangoHud.conf` after the preset and its row settings would win in every
layout. Use GOverlay only to preview other settings: Home Manager owns these
files, so copy a setting you keep into the module.

The extra rows each read one sysfs file: EPP and the sched_ext scheduler on
both PCs, and the platform profile and AC on nixos-rog only.
