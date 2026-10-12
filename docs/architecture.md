# How the flake fits together

The flake builds `nixos-latitude` and `nixos-rog`. `nixos-desktop` remains an inert
inventory record until its real hardware configuration and host policy exist.

Shared NixOS policy lives in `nixosModules/`, and active host files live in
`machines/<host>/`. The typed `oruc.machine` record in `machines/inventory.nix` is
the source of the host name, hardware-neutral machine facts, the boot loader, the
login sessions (each a desktop with its shell; the first is the default), the
launcher, the idle and touchpad settings, and optional service gates. Every session reads the same idle
and touchpad settings: Plasma through powerdevil and kcminputrc, niri through the
touchpad section of `/etc/niri/host.kdl` and one swayidle service
(`home-manager/modules/idle.nix`) under either shell. By default the screen dims
after 2 minutes and turns off after 5 on battery, never on AC, and never locks
or suspends. `nixosModules/theme.nix` derives the read-only
`oruc.theme` values (variant, cursor, icons, wallpaper, ANSI slots) from the
selected Base16 scheme. Home Manager is integrated through
`nixosModules/home-manager.nix`, which loads `home-manager/common.nix`; a host
adds its own layer from `machines/<host>/home.nix`.

`kernel-cache/` is a separate flake that GitHub Actions builds into the
`omerfarukoruc` Cachix cache: the CachyOS kernel, the NVIDIA open module and
DankMaterialShell. Its [README](../kernel-cache/README.md) explains how the hosts
follow it.
