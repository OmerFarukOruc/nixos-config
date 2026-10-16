# How the flake fits together

- [Inventory](#inventory)
- [Login sessions](#login-sessions)
- [Add a host, launcher, shell or kernel profile](#add-a-host-launcher-shell-or-kernel-profile)
- [Theme](#theme)
- [Home Manager](#home-manager)
- [kernel-cache](#kernel-cache)

The flake builds `nixos-latitude` and `nixos-rog`. `nixos-desktop` stays an
inert inventory record until its real hardware configuration and host policy
exist.

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

`machines/inventory.nix` holds one value per machine for the typed
`oruc.machine` option that `nixosModules/machine.nix` declares. A record holds:

- the host name, system, kind, form factor, GPU class and battery flag
- the boot loader
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
  start only when it matches. For niri the launcher also sets `NIRI_CONFIG` to
  a file that adds the shell's binds after `/etc/niri/config.kdl`.
  A niri session that is already open misses a deploy that changes the
  launcher. [Deploy](deploy.md#deploy) says how to tell and what to do.
- **Plasma owns the shared look.** With Plasma present, Plasma owns
  `kdeglobals`, the GTK settings and the cursor, and the niri session inherits
  them. A niri-only machine keeps the files that Home Manager writes.

## Add a host, launcher, shell or kernel profile

- **A host.** Add a record to `rawMachines` in `machines/inventory.nix`. A record
  alone stays inert, as `nixos-desktop` does. To build the host, add a
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
  the cache to hold a CachyOS profile's build, name it
  `cachyos-latest-lto-<variant>` and set its `package` to
  `[ "cachyosKernels" "linuxPackages-cachyos-latest-lto-<variant>" ]`. Then add `<variant>` to
  `variants` and a `hostPackages` entry (an empty list is valid) in
  `kernel-cache/flake.nix`. The kernel-cache workflow reads `variants`.

## Theme

`nixosModules/theme-module.nix` derives the read-only `oruc.theme` values from
a Base16 scheme. The values are whether the scheme is light, the cursor, icons
and GTK theme that follow that variant, the wallpaper named after the scheme,
and the ANSI slots. The font families are fixed.

NixOS and Home Manager each import that module with their own scheme:

- NixOS (`nixosModules/theme.nix`) uses `theme.scheme` from the machine record.
  The login screen, the boot menu, the console and niri read it.
- Home Manager (`home-manager/modules/scheme.nix`) uses `oruc.scheme`, which
  starts as `theme.scheme`. Every app that Home Manager configures reads
  `config.scheme` and `config.oruc.theme`, never the NixOS values.

`theme.schemes` in the machine record lists other schemes. Each one, with each
Plasma look, is a Home Manager variant (`machines/variants.nix`): the
generation itself for the record's scheme and default look, and a
specialisation for each other pair (`home-manager/modules/variants.nix`).
`theme <scheme>` activates one at run time and keeps it across deploys
([Switch the scheme](nixos-rog.md#switch-the-scheme)). Every variant adds a
Home Manager evaluation to each deploy. With two looks and four schemes,
`scripts/eval-on-rog.sh` took 59 to 66 seconds for nixos-rog's system in 3
runs, against 29 to 46 seconds in 4 runs with one scheme (measured
2026-10-16).

NixOS installs only the generation's own packages, so a specialisation
cannot change one. A color therefore reaches an app through a file that Home
Manager writes, never through a package built with it. Neovim, the VS Code
window and fzf read their colors from files for this reason. kVitals' package
defaults and, on a host without Plasma, the cursor keep the record's scheme. `nixosModules/hm-variants.nix`
fails the evaluation when a variant's packages differ from the generation's,
and names them.

`assets/schemes` holds the schemes that tinted-theming lacks. The
`warm-burnout-dark` and `warm-burnout-light` schemes there copy the palette of
the `warm-burnout` input's pinned commit. With either of them,
`home-manager/modules/theme.nix` also installs that input's own VS Code
extension and Neovim color scheme in place of the Base16 ones. To move the
input, change its commit in `flake.nix`, compare the new palette
(`nvim/lua/warm-burnout/palette.lua`) with the two scheme files, and check that
the VS Code theme labels and Neovim color scheme names still match
`home-manager/modules/theme.nix`.

`theme.plasmaLook` names the default Plasma look. `plasma-look` activates
another look at run time, with the same variants
([Plasma looks](nixos-rog.md#plasma-looks)).

`scripts/check-theme-drift.sh` runs inside `nix fmt` and fails on a fixed color
in a tracked file: `#RRGGBB`, `#RRGGBBAA` (and `#RGB` in CSS), or a number
inside `rgb(`, `rgba(`, `hsl(`, `hsla(`, `oklch(` or `oklab(`. `#000000` and
`#00000000` pass, because black and full transparency carry no hue. A line that
holds `theme-drift-ok: <reason>` passes. A file listed in
`scripts/theme-drift-allow.txt` (`path-or-glob`, a tab, a reason) passes, and
the check fails when an entry matches no tracked file, so the list cannot go
stale. It cannot see a hex string without `#`, a decimal triple, a color name
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
- Brave keeps its synced theme, because a managed theme policy would lock the
  setting and override the synced one (`nixosModules/brave.nix`).
- Grok and Codex themes live outside this repository.

## Home Manager

`nixosModules/home-manager.nix` integrates Home Manager and loads
`home-manager/common.nix`. A host adds its own layer from
`machines/<host>/home.nix`.

## kernel-cache

`kernel-cache/` is a separate flake. GitHub Actions builds it into the
`omerfarukoruc` Cachix cache. The cache holds the CachyOS kernels, the NVIDIA
open modules, and ryzen-smu and turbostat for zen4. The
[kernel-cache README](../kernel-cache/README.md) explains how the hosts follow
it.

The same cache holds the host packages in `ci/cached-packages.nix`, which the
host-packages-cache workflow builds from each host's configuration.
[nixos-rog.md](nixos-rog.md#cached-packages) explains how the updater waits for
them.
