# How the flake fits together

- [Inventory](#inventory)
- [Login sessions](#login-sessions)
- [Add a host, launcher, shell or kernel profile](#add-a-host-launcher-shell-or-kernel-profile)
- [Theme](#theme)
- [Secrets](#secrets)
- [Home Manager](#home-manager)
- [nixos-desktop case fans](#nixos-desktop-case-fans)

The flake builds `nixos-desktop`, `nixos-latitude`, `nixos-rog` and `devbox`.

## Inventory

Shared NixOS policy lives in `nixosModules/`. Active host files live in
`machines/<host>/`.

`nixosModules/default.nix` imports the modules every host uses, and it imports
`nixosModules/workstation.nix`, which lists the workstation modules. Each module
turns itself on from the machine record. It reads `kind`, `gpu` or a
`features.*` switch, or it asks the `sessions` helpers (the module argument that
`nixosModules/machine.nix` passes) which desktops and shells the machine offers.
A new module goes in one of the two import lists and gates its own config on the
record.

A machine of kind `server` gets none of the workstation modules. Each of them
gates on `kind == "workstation"`, on a feature, on the machine's `gpu`
(`intel-graphics.nix` and `amd-graphics.nix`), or on the machine's sessions, and
the modules for graphical apps, the wallpaper and the failure popup skip a
machine with no session, and the fonts skip one with no graphical user.
`connectivity.nix` (NetworkManager, SSH and sudo) is workstation-only, so the schema rejects `features.remoteAccess` on a server, and
it rejects `theme.schemes`, because only a workstation gets the `theme` command.
`nixosModules/tailscale.nix` and `nixosModules/ssh.nix` (the settings every
sshd shares) serve every host, and `nixosModules/server-access.nix` adds a
server's Tailscale flags and SSH ([devbox](devbox.md#access)). `ci/server.nix` evaluates a
server record with no sessions, and `ci/checks.sh` fails when one of the pieces
it lists comes in or when the schema stops rejecting one of the four records it
rejects: `theme.schemes` or `features.remoteAccess` on a server, `biosDevice`
with systemd-boot, and `features.streamedDesktop` on a workstation.

A server has a desktop through `features.streamedDesktop`, not through a login
session: `nixosModules/streamed-desktop.nix` starts XFCE for each RDP login of
omer over the tailnet ([Streamed desktop](devbox.md#streamed-desktop)).
`features.remoteDesktop` stays the workstation's switch for Sunshine on its own
screen, and it still requires `remoteAccess`. The session list of such a server
stays empty, so the modules that ask `sessions.hasAnyDesktop` (the login screen,
Ghostty, the wallpaper, VS Code, the launchers) skip it. The modules that give a
graphical user fonts, a browser, its certificate database and the keyboard layout
ask `sessions.hasGraphicalUser`, which is true for a login session or a streamed
desktop. `ci/checks.sh` lists the pieces a server with a streamed desktop gets.

`nixosModules/bootloader.nix` sets `boot.loader.efi.canTouchEfiVariables` to true
as a default. A machine that boots through BIOS sets it to false, because its
firmware keeps no boot entries to write. Limine then installs its EFI binary at
the firmware fallback path only. With `biosDevice` in the record, Limine also
installs its BIOS stage on that disk, so one disk is laid out for either
firmware; devbox's VM test boots it through BIOS only.

`machines/inventory.nix` holds one value per machine for the typed
`oruc.machine` option that `nixosModules/machine.nix` declares. A record holds:

- the host name, the login user, system, kind, form factor, GPU class and battery flag
- the boot loader, and for Limine the disk that also gets its BIOS stage
- the kernel profile and the Base16 scheme
- the login sessions, described in [Login sessions](#login-sessions)
- the launcher
- the idle and touchpad settings
- optional service gates

The other files in `machines/` define what a record may hold:

- `schema.nix` declares each option, its default, and the checks that reject an
  invalid record. For example, only a workstation offers a desktop session.
- `selectors.nix` lists the valid launchers, shells and kernel profiles, and the
  desktops that each launcher and shell supports.
- `schemes.nix` maps each Base16 scheme name to its file, from the pinned
  tinted-theming input or `assets/schemes`.
- `sessions.nix` has the `sessions` helpers.
- `variants.nix` lists the Home Manager variants of a record: one per Plasma
  look and scheme ([Theme](#theme)).

Every session reads the same idle and touchpad settings. Plasma reads the idle
settings through powerdevil (`home-manager/modules/plasma-manager.nix`). It reads
the touchpad settings through a kcminputrc entry for the touchpad's device id,
which each Plasma host writes in its own `home.nix`
(`machines/nixos-rog/home.nix`). niri reads the touchpad section of
`/etc/niri/host.kdl` and one swayidle service (`home-manager/modules/idle.nix`)
under either shell. A machine with no battery uses only the AC idle values under
niri.

By default, on battery, the screen dims after 2 minutes and turns off after 5.
On AC it does neither. The screen never locks, and the machine never suspends.

## Login sessions

nixos-rog offers Plasma, niri with Noctalia and niri with DMS from the same
display manager. So a machine record holds a list of login sessions. Each
session is a desktop with its shell, and the first session is the default.

The list is one record field, with no per-desktop host overrides, because every
consumer (login, desktop, theme, launchers, shells) must agree on which
desktops exist.

These rules follow from the list:

- **Session units.** Every session reaches `graphical-session.target`, so a
  user service that belongs to one desktop binds to that desktop's own unit
  instead. Units this repository writes for Plasma name
  `plasma-workspace.target` directly. Units that Home Manager modules define
  for niri register in `oruc.sessionServices`, or in `oruc.shellServices` when
  one shell owns them. On a machine with more than one session, the
  registration rebinds them to `niri.service`.
- **One session per shell.** A desktop with more than one shell gets one
  display manager session per shell, named `<desktop>-<shell>`, in place of its
  own. The session's launcher sets `ORUC_SHELL`, and each shell's services
  start only when it matches. Every niri shell's launcher sets `NIRI_CONFIG` to
  `/etc/niri/<session>.kdl`, which includes `/etc/niri/config.kdl`
  (`niri/config.kdl`, the system-wide niri config) and then the shell's binds.
  The file is `niri-<shell>.kdl` when the machine has several niri shells and
  `niri.kdl` when it has one (`sessionName` in `machines/sessions.nix`). Because
  `NIRI_CONFIG` is set, niri does not read `~/.config/niri/config.kdl`.
  A niri session that is already open misses a deploy that changes the
  launcher. [Deploy](deploy.md#deploy) says how to tell and what to do.
- **Plasma owns the shared look.** With Plasma present, Plasma owns
  `kdeglobals`, the GTK settings and the cursor, and the niri session inherits
  them. A niri-only machine keeps the files that Home Manager writes. The GTK
  colors and the GTK 3 theme name are the exceptions. Plasma's `gtk.css` is a
  regular file that kded rewrites, so Home Manager links `oruc-colors.css`
  beside it and an activation step adds the `@import` line to `gtk.css`.
  `oruc-polarity` sets the GTK 3 theme to adw-gtk3 (the dark one for a dark
  scheme) in `settings.ini` and in dconf, but only while the theme is unset or
  already adw-gtk3, so a theme chosen in System Settings stays.
- **Blur rules.** Blur shows only through translucent pixels, so the
  `window-rule` and `layer-rule` blocks in `niri/config.kdl` are an allow-list of
  surfaces that are translucent. niri enables xray blur with any background
  effect, which blurs the wallpaper once and reuses it. The DMS dock is not on
  the list, because DMS requests blur for the dock's own shape. A rule that
  matched the dock's full-width surface painted a dark strip about 90 px tall
  over the bottom of the windows (observed 2026-09-21).

## Add a host, launcher, shell or kernel profile

- **A host.** Add a record to `rawMachines` in `machines/inventory.nix`. A record
  alone stays inert. To build the host, add a
  `nixosConfigurations.<name>` block in the same file, with `hostModules` that
  name `machines/<name>/configuration.nix` and `hardware-configuration.nix`.
- **A launcher.** Add it to `launcherSpecs` in `machines/selectors.nix` and
  create `home-manager/modules/launchers/<name>.nix`. `launchers/default.nix`
  imports a file for each name in `selectors.nix`.
- **A shell.** Add it to `shellSpecs` in `machines/selectors.nix` and create
  `home-manager/modules/shells/<name>.nix`. A niri shell also needs
  `niri/shells/<name>.kdl` with its binds, because niri treats a missing include
  as an error.
- **A kernel profile.** Add it to `kernelSpecs` in `machines/selectors.nix`. For
  a CachyOS profile, set its `package` to
  `[ "cachyosKernels" "linuxPackages-cachyos-<variant>" ]` with a variant that
  upstream's cache holds; [nix-cachyos-kernel's README](https://github.com/xddxdd/nix-cachyos-kernel#which-kernel-versions-are-provided)
  marks the variants it does not cache ([The kernel](updates.md#the-kernel)).

## Theme

`nixosModules/theme-module.nix` sets the read-only `oruc.theme` values of a
Base16 scheme. `nixosModules/theme-values.nix` gives whether the scheme is
light, the cursor, icons and GTK theme that follow that variant, and the ANSI
slots; the module adds the wallpaper and the fixed font families. The theme
pack calls `theme-values.nix` for every scheme.

NixOS and Home Manager each import that module with their own scheme:

- NixOS (`nixosModules/theme.nix`) uses `theme.scheme` from the machine record.
  The login screen, the boot menu, the console and niri read it.
- Home Manager (`home-manager/modules/scheme.nix`) uses `oruc.scheme`, which
  starts as `theme.scheme`. Every app that Home Manager configures reads
  `config.scheme` and `config.oruc.theme`, never the NixOS values.

The wallpaper is the file in `assets/wallpapers` named after the scheme. A scheme
without one gets `assets/wallpapers/default.png` recolored to the scheme's 16
colors by lutgen, in a derivation of `theme-module.nix`. The derivation reads a
file in the repository, so it needs no import from derivation, and the
recoloring runs in the build of each variant.

`theme.schemes` in the machine record lists other schemes. Each one, with each
Plasma look, is a Home Manager variant (`machines/variants.nix`). With Plasma,
there is one row per look and scheme. Without Plasma, there is one row per
scheme, and that row has no look. The row of the record's scheme, and of
`theme.plasmaLook` when the machine has Plasma, is the Home Manager generation.
Each other row is a specialisation (`home-manager/modules/variants.nix`), which
`plasma-look` and `theme` activate (`nixosModules/hm-variants.nix`). The `name`
function in `machines/variants.nix` is the only encoder of a specialisation's
directory. The shell commands read the finished rows and do not rebuild them.

`plasma-look <look>` and `theme <scheme>` each store a choice and activate the
variant of both stored choices
([Switch the scheme](nixos-rog.md#switch-the-scheme)). A scheme outside
`theme.schemes` uses the record scheme's variant. Each deploy and each boot
activates the default variant first, so the Home Manager service then runs
`theme --reapply`, which activates the stored one. Every variant adds a
Home Manager evaluation to each deploy. With two looks and four schemes,
an evaluation of nixos-rog's system on nixos-rog took 59 to 66 seconds in 3
runs, against 29 to 46 seconds in 4 runs with one scheme (measured
2026-10-16).

NixOS installs only the generation's own packages, so a specialisation
cannot change one. A color therefore reaches an app through a file that Home
Manager writes, never through a package built with it. Neovim, the VS Code
window and fzf read their colors from files for this reason. kVitals' package
defaults and, on a host without Plasma, the cursor keep the record's scheme. `nixosModules/hm-variants.nix`
fails the evaluation when a variant's packages differ from the generation's,
and names them.

The apps that read their colours from a file follow any scheme without a
variant, through the theme pack (`home-manager/modules/theme-pack.nix`). Each
module adds a renderer to `oruc.themeFiles`, keyed by the file's path under
`$HOME`, and the pack, a store path in the generation, holds each renderer's
file for each scheme as `<scheme>/<path>`, with a `slugs` file that lists the
schemes and, per scheme, `.oruc/polarity` (dark or light) and the scheme's YAML
as `.oruc/source.yaml`. Each such file in `$HOME` links to
`~/.local/state/oruc/theme/current/<path>`, and `current` links to
`pack/<scheme>`. `theme/pack` links to the generation's pack and is a GC root.
`oruc-theme-pointer` owns these links and holds `theme/lock` while it changes
them. `theme` and `plasma-look` hold `switch.lock` for a whole switch, so two
runs cannot leave the active variant and the stored scheme apart, and they
refuse to activate a variant once a deploy replaced the system they came
from. Each Home Manager activation roots its own pack, so a rollback brings
the old pack back, and points `current` at the stored scheme
(`~/.local/state/oruc/scheme`), or at the record scheme when the pack lacks
it. `theme <scheme>` replaces the stored scheme through a rename, which is the
one step that commits a switch, points `current` at it, and then runs
`oruc.variantReloads` so Ghostty, tmux and Neovim load the new files. Claude
Code reloads its theme when the file is replaced, but not when a link on its
path changes target, so its theme file is listed in `oruc.themeCopies`: the
pointer writes it as a regular file and replaces it through a rename each time
it moves `current`. A renderer runs for every scheme, so it must give a valid file for
each; the Markdown viewer's code colours move toward black or white when the
scheme's foreground cannot reach 4.5:1 on the code background. Specialisations
reuse the generation's pack, and root's Home Manager and the servers get a
pack with the record scheme alone. `oruc.themeFacts` adds a one-line value per
scheme to the pack as `.oruc/<name>`, such as the Glass glow colour.

On Plasma, `theme` then runs `oruc-plasma-live`
(`home-manager/modules/plasma-looks/default.nix`), which changes the running
session:

- **KDE colours.** The pack holds the opaque `OrucBase16.colors` of Klassy and
  the translucent `OrucBase16Glass.colors` of Glass under
  `.local/share/oruc/kde/`. `plasma-apply-colorscheme` does nothing for the
  scheme that is already selected, so `oruc-kde-colors` copies the file to the
  `A` or `B` name that `kdeglobals` does not hold, such as `OrucBase16GlassB`,
  and applies that copy. KDE apps repaint, and kded writes the GTK colours of
  the new scheme. When the copy that runs already matches the pack's file, it
  changes nothing.
- **Dark or light set.** `oruc-polarity` (`home-manager/modules/appearance.nix`)
  gives the session the cursor, icons, GTK 3 theme name and dconf
  `color-scheme` of the scheme's variant, which the pack holds as the facts
  `cursor`, `icons`, `gtk` and `polarity`. It does this at each login and when
  the variant changed, and records the variant in
  `~/.local/state/oruc/theme/polarity`. Otherwise it sets `color-scheme` to
  `default` and back, so GTK 4 apps load `oruc-colors.css` again.
- **Plasma style.** `looks` in `plasma-looks/default.nix` names each look's
  colour scheme and Plasma style: `oruc-glass`, or `klassy-dark` and
  `klassy-light` by the variant. plasma-manager runs its theme script only when
  the script's text changed since its last run, so a switch back to a look
  would skip it; `oruc-plasma-live` sets the style instead.
- **Glass glow.** With the Glass colours, it writes the pack's `.oruc/glow` to
  `kwinrc` and reconfigures the effect when the colour differs.

`theme` takes the look from the KDE colour scheme that runs, so a
`plasma-look` that waits for the next login does not change the running
session's look. The login unit `oruc-plasma-colors` runs the same steps with
`--login` and the generation's look once per Plasma login, so a new login shows
the stored scheme and look; `oruc-niri-colors` applies the opaque colours once
per niri login on a host that also has Plasma. A deploy or `plasma-look` never
changes the KDE colours of a running session, because a live colour scheme
change crashed Discord on 2026-10-16; `theme` does, because switching the
scheme asks for it.

`machines/scheme-parser.nix` reads each scheme file line by line, because
base16.nix's YAML parser fails on 14 tinted-theming files, such as `dracula`
and `ascendancy`. It reads only `name`, `author`, `variant` and the 16 palette
colours, and fails with the file and key on a value it cannot read, such as a
backslash escape, and on anything else in the palette. The `scheme-catalogue`
flake check, which `ci/checks.sh` builds, compares its result for every file
with `yq`'s.

`assets/schemes` holds the schemes that tinted-theming lacks. The
`warm-burnout-dark` and `warm-burnout-light` schemes there copy the palette of
the `warm-burnout` input's pinned commit (github:felipefdl/warm-burnout v1.8.0,
`nvim/lua/warm-burnout/palette.lua`). Some slots are derived, not copied:

- In both schemes, `base06` lies halfway between `base05` and `base07`.
- In `warm-burnout-dark.yaml`, `base07` comes from the theme's Home Assistant
  version, `base02` is the translucent selection and `base03` the gutter color,
  each drawn over the background.
- In `warm-burnout-light.yaml`, `base02` is the VS Code theme's translucent
  selection drawn over the background.

With either of them,
`home-manager/modules/theme.nix` also installs that input's own VS Code
extension and Neovim color scheme in place of the Base16 ones. To move the
input, change its commit in `flake.nix`, compare the new palette
(`nvim/lua/warm-burnout/palette.lua`) with the two scheme files, and check that
the VS Code theme labels and Neovim color scheme names still match
`home-manager/modules/theme.nix`.

Every other scheme gets a VS Code theme that `theme.nix` renders from the
`tinted-vscode` input's pinned `base16` template, and `vscode.nix` rewrites the
fixed colors in the vibrancy input's stylesheet with the scheme's.
Evaluation fails when that stylesheet no longer holds a color that
`vscode.nix` rewrites.

`theme.plasmaLook` names the default Plasma look, and a machine with no Plasma session leaves it null. `plasma-look` activates
another look at run time, with the same variants
([Plasma looks](nixos-rog.md#plasma-looks)).

`scripts/check-theme-drift.sh` runs inside `nix fmt` and fails on a fixed color
in a tracked file: `#RRGGBB`, `#RRGGBBAA` (and `#RGB` in CSS), or a number
inside `rgb(`, `rgba(`, `hsl(`, `hsla(`, `oklch(` or `oklab(`. `#000000` and
`#00000000` pass, because black and full transparency carry no hue. A line that
holds `theme-drift-ok: <reason>` passes. A file listed in
`scripts/theme-drift-allow.txt` (`path-or-glob`, a tab, a reason) passes, and
the check fails when an entry matches no tracked file, so the list cannot go
stale. It does not read Markdown, lock files or `assets/`. It cannot see a hex string without `#`, a decimal triple, a color name
or a default inside a package, so a new package or module whose UI has colors
takes them from `config.scheme` or `oruc.theme.ansi`, or lands in the list
below with its reason.

These stay fixed on purpose, and the check does not cover them:

- Web pages and Electron app interiors follow only the dark or light variant,
  through the desktop portal.
- niri's hotkey overlay, screenshot UI and error banner.
- The Bibata cursor and the Papirus icons (the variant follows the scheme), and
  the icons of wlogout.
- The Breeze desktop theme SVGs (their colors come from kdeglobals at run time)
  and the Glass Qt style.
- mpv subtitles.
- The print stylesheet of the Markdown viewer.
- Spotify follows only the machine record's scheme, because Spicetify builds
  the colors into its package.
- The keyboard's Aura color follows only the machine record's scheme, because
  asusd reads it from a system file (`machines/nixos-rog/asus.nix`).
- Brave keeps its synced theme, because a managed theme policy would lock the
  setting and override the synced one. `nixosModules/brave.nix` writes Brave's
  settings as policies, which Brave Origin reads from `/etc/brave/policies`. The
  recommended policies set the values a new profile starts with, and the
  settings page can still change them. Notification permissions and the theme
  color are managed-only policies, and Brave Sync carries them, so they stay in
  the profile.
- Grok and Codex themes live outside this repository.

## Secrets

`.sops.yaml` lists the recipients of the encrypted files under `secrets/`. Omer
edits them with the SSH key he shares across his devices,
`~/.ssh/id_ed25519_omer`. Each host decrypts its own file with the age key
derived from its SSH host key (`ssh-to-age` on
`/etc/ssh/ssh_host_ed25519_key.pub`). [Secrets](nixos-rog.md#secrets) says how
to edit a file.

## Home Manager

`nixosModules/home-manager.nix` integrates Home Manager and loads
`home-manager/common.nix`. A host adds its own layer from
`machines/<host>/home.nix`. Shared app sets are in `home-manager/profiles/`:
`workstation.nix` for every workstation, and `personal.nix` for the machines
Omer works at every day, with GPU tools that follow the machine record. Units a
host can share, such as desktop-sync, are in `home-manager/modules/`.

## nixos-desktop case fans

`machines/nixos-desktop/fans.nix` runs `case-fans.service`, a daemon
(`fan-control.py`) that owns channels 1, 3, 5 and 7 of the motherboard's
nct6687 chip: the radiator fans, the rear fan and the two intake chains. Every
2 s it turns the filtered CPU (`k10temp` Tctl) and GPU (`amdgpu` edge)
temperatures into a target RPM per channel, and sets the PWM that holds that
RPM from each channel's tach reading and its measured PWM-to-RPM table. In
normal mode the intake target never drops below 0.85 x the radiator RPM plus
0.30 x the rear RPM, so the case keeps positive pressure; at a filtered Tctl of
85 C or a raw Tctl of 89 C all four channels run at full speed instead. The
curves and pressure weights live in `settings` in `fans.nix`, and the measured
tables in `fan-tables.json`. To measure a channel's table again, stop the
service and run the measurement as a transient unit, so the channel returns to
the BIOS however the run ends:

```sh
sudo systemctl stop case-fans
sudo systemd-run --wait --pipe -p ExecStopPost="$(command -v case-fans-control) --restore N" "$(command -v case-fans-control)" --calibrate N
sudo systemctl start case-fans
```

The measurement aborts when Tctl reaches 70 C, so run it while the machine is
idle.

When the daemon stops, crashes, misses its 10 s watchdog or cannot read a
sensor, `ExecStopPost` hands the four channels back to the BIOS curves. The
BIOS keeps the pump (channel 2) and the AIO's VRM fan (channel 4). `case-fans
off` stops the daemon until `case-fans on` or the next boot (`on` also clears
the start limit that 3 failures in 10 minutes set), `case-fans status`
prints its state file, and `fan-status` lists every fan.

