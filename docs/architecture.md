# How the flake fits together

The flake builds `nixos-latitude` and `nixos-rog`. `nixos-desktop` stays an
inert inventory record until its real hardware configuration and host policy
exist.

## Inventory

Shared NixOS policy lives in `nixosModules/`. Active host files live in
`machines/<host>/`.

The typed `oruc.machine` record in `machines/inventory.nix` is the source of
these host facts:

- the host name
- hardware-neutral machine facts
- the boot loader
- the login sessions, described in [Login sessions](#login-sessions)
- the launcher
- the idle and touchpad settings
- optional service gates

Every session reads the same idle and touchpad settings:

- Plasma reads them through powerdevil and kcminputrc.
- niri reads them through the touchpad section of `/etc/niri/host.kdl` and one
  swayidle service (`home-manager/modules/idle.nix`) under either shell.

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
- **Plasma owns the shared look.** With Plasma present, Plasma owns
  `kdeglobals`, the GTK settings and the cursor, and the niri session inherits
  them. A niri-only machine keeps the files that Home Manager writes.

## Theme

`nixosModules/theme.nix` derives the read-only `oruc.theme` values (variant,
cursor, icons, wallpaper, ANSI slots) from the selected Base16 scheme.

## Home Manager

`nixosModules/home-manager.nix` integrates Home Manager and loads
`home-manager/common.nix`. A host adds its own layer from
`machines/<host>/home.nix`.

## kernel-cache

`kernel-cache/` is a separate flake. GitHub Actions builds it into the
`omerfarukoruc` Cachix cache. The cache holds the CachyOS kernel and the NVIDIA
open module. The [kernel-cache README](../kernel-cache/README.md)
explains how the hosts follow it.

The same cache holds the host packages in `ci/cached-packages.nix`, which the
host-packages-cache workflow builds from each host's configuration.
[nixos-rog.md](nixos-rog.md#cached-packages) explains how the updater waits for
them.
