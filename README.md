<div align="center">

<img src="https://raw.githubusercontent.com/NixOS/nixos-artwork/master/logo/nix-snowflake-colours.svg" width="96" alt="NixOS snowflake">

# nixos-config

**Two NixOS laptops in one flake, deployed from a Fedora desktop over Tailscale,<br>
with a CachyOS kernel that CI compiles so the laptops never do.**

[![NixOS unstable](https://img.shields.io/badge/NixOS-unstable-5277C3?style=flat-square&logo=nixos&logoColor=white)](https://github.com/NixOS/nixpkgs/tree/nixos-unstable)
[![check](https://img.shields.io/github/actions/workflow/status/OmerFarukOruc/nixos-config/check.yml?branch=main&style=flat-square&label=check&logo=github)](https://github.com/OmerFarukOruc/nixos-config/actions/workflows/check.yml)
[![kernel-cache](https://img.shields.io/github/actions/workflow/status/OmerFarukOruc/nixos-config/kernel-cache.yml?branch=main&style=flat-square&label=kernel-cache&logo=linux&logoColor=white)](https://github.com/OmerFarukOruc/nixos-config/actions/workflows/kernel-cache.yml)
[![host-packages-cache](https://img.shields.io/github/actions/workflow/status/OmerFarukOruc/nixos-config/host-packages-cache.yml?branch=main&style=flat-square&label=host-packages-cache)](https://github.com/OmerFarukOruc/nixos-config/actions/workflows/host-packages-cache.yml)
[![Cachix](https://img.shields.io/badge/cachix-omerfarukoruc-4E7FC1?style=flat-square)](https://omerfarukoruc.cachix.org)

[Hosts](#hosts) · [Highlights](#highlights) · [Layout](#layout) · [Everyday commands](#everyday-commands) · [Docs](#docs)

<img src="assets/screenshots/nixos-rog-plasma-fastfetch.webp" width="90%" alt="nixos-rog running KDE Plasma with fastfetch in Ghostty">

<sub>nixos-rog · KDE Plasma · Ghostty · Gruvbox Dark Medium from Base16</sub>

</div>

<details>
<summary>Bare desktop</summary>
<br>
<img src="assets/screenshots/nixos-rog-plasma-desktop.webp" alt="nixos-rog Plasma desktop with the dock and the top panel">
</details>

## Hosts

| Host | Role | Machine | Login sessions | Kernel | Boot |
| --- | --- | --- | --- | --- | --- |
| `nixos-rog` | daily laptop | ASUS ROG Zephyrus G16 GA605WI, Ryzen AI 9 HX 370, RTX 4070 | Plasma · niri + Noctalia · niri + DMS | CachyOS LTO `zen4` | Limine, next to Windows |
| `nixos-latitude` | home lab box | Dell Latitude 3550 | niri + Noctalia | CachyOS LTO `x86_64-v3` | systemd-boot |
| `nixos-desktop` | planned | the PC that runs fedora-desktop today | | | |

`machines/inventory.nix` is the source of truth for this table. `nixos-desktop`
is an inventory record only; the flake does not build it.

## Highlights

- **🧊 A kernel the laptops download.** The [`kernel-cache`](kernel-cache/README.md)
  flake builds the CachyOS LTO kernel, the NVIDIA open module, ryzen-smu and
  turbostat on GitHub Actions and pushes them to the `omerfarukoruc` Cachix
  cache. `scripts/update-kernel.sh` moves a host only to a revision whose every
  path is already in that cache.
- **🪟 Three desktops, one theme.** nixos-rog offers Plasma, niri with Noctalia
  and niri with DankMaterialShell at the login screen. One Base16 scheme sets the
  colors, cursor, icons and wallpaper of all of them, and of SDDM.
- **🛟 Deploys that roll themselves back.** `deploy.sh` builds on the target,
  activates under a 420 second rollback timer, then checks SSH, Tailscale and
  the user's running services. A deploy that breaks any of them restores the
  previous system, even when the connection drops.
- **🔄 A laptop that updates itself.** Every hour on AC power, nixos-rog moves its
  inputs and apps, waits for the caches to hold the expensive builds, deploys the
  result to itself and squash-merges it to `main`.
- **🔐 Secrets bound to the machine.** sops-nix decrypts `secrets/nixos-rog.yaml`
  with the age key derived from the laptop's SSH host key.
- **🧭 Private DNS everywhere.** DNS goes only to NextDNS over TLS, with a
  `captive-dns` switch for Wi-Fi sign-in pages.

## Layout

```text
flake.nix              inputs and the two nixosConfigurations
machines/              the typed host inventory and one folder per host
nixosModules/          shared NixOS policy: kernel, boot, desktop, login, theme, ...
home-manager/          the user layer, with one module per shell and app
niri/                  niri config shared by the Noctalia and DMS sessions
pkgs/  overlays/       apps that nixpkgs lacks, and fixes to nixpkgs packages
kernel-cache/          the separate flake that CI builds into Cachix
scripts/               update, verify and auto-update scripts
deploy.sh              the deploy with build, confirm and rollback
secrets/  .sops.yaml   sops-encrypted values and their recipients
docs/                  operating guides and the architecture
```

[docs/architecture.md](docs/architecture.md) explains how the inventory, the
login sessions, the theme and Home Manager connect.

## Everyday commands

Run these from fedora-desktop, which has no Nix; `deploy.sh` builds on the
target.

| Command | What it does |
| --- | --- |
| `./deploy.sh nixos-rog` | build, activate, confirm and make it the boot default |
| `./deploy.sh nixos-rog test` | activate until the next reboot only |
| `./deploy.sh nixos-rog boot` | set the boot default without activating |
| `./deploy.sh nixos-rog prune` | delete old release copies, keeping the five newest |
| `scripts/update-kernel.sh` | move the kernel to the newest cached build |
| `scripts/move-inputs.sh` | move inputs to their newest release or branch head, except the kernel and llm-agents |
| `scripts/update-release-tags.sh` | move release-pinned inputs to their newest tag |
| `scripts/update-app.sh NAME` | move `pkgs/NAME.nix` to the vendor's newest release |
| `scripts/verify-nixos-rog.sh` | check the running laptop and write a JSON report |

Every deploy command can change boot or running system state.
CI runs the formatter, `nix flake check --no-build` and the evaluation of each
host on every pull request and push to `main`.

## Docs

| Guide | Covers |
| --- | --- |
| [Deploy](docs/deploy.md) | evaluation checks, the deploy and rollback steps, exit codes, release records |
| [Updates](docs/updates.md) | the kernel, release-tagged inputs and app packages |
| [Recovery](docs/recovery.md) | rollback, older generations, the recovery kernel, bootloader repair |
| [nixos-rog](docs/nixos-rog.md) | the hourly updater, secrets, DNS and the post-deploy check |
| [Install nixos-latitude](docs/install-nixos-latitude.md) | a first install from the NixOS ISO |
| [kernel-cache](kernel-cache/README.md) | how CI builds the kernel and how hosts follow it |
| [Home Manager](home-manager/README.md) | the user layer and the services a switch leaves running |
| [CONTEXT.md](CONTEXT.md) | the domain terms |

## Built on

[nix-cachyos-kernel](https://github.com/xddxdd/nix-cachyos-kernel) ·
[home-manager](https://github.com/nix-community/home-manager) ·
[plasma-manager](https://github.com/nix-community/plasma-manager) ·
[base16.nix](https://github.com/SenchoPens/base16.nix) ·
[sops-nix](https://github.com/Mic92/sops-nix) ·
[niri](https://github.com/YaLTeR/niri) ·
[Noctalia](https://github.com/noctalia-dev/noctalia-shell) ·
[DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) ·
[SilentSDDM](https://github.com/uiriansan/SilentSDDM) ·
[llm-agents.nix](https://github.com/numtide/llm-agents.nix)
