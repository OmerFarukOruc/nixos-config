# risoluto-dev-1

- [What it is](#what-it-is)
- [Disk and boot](#disk-and-boot)
- [Access](#access)
- [Install](#install)
- [Network and secrets](#network-and-secrets)
- [Boot test in a VM](#boot-test-in-a-vm)

## What it is

risoluto-dev-1 is Omer's dev box, a netcup KVM guest with one 2 TiB virtio disk.
It is the first host with `kind = "server"` in `machines/inventory.nix`: no
login session, no workstation module, and the kernel from nixpkgs. Its files are
`machines/risoluto-dev-1/` (`configuration.nix`, `disk.nix`,
`hardware-configuration.nix`) and `nixosModules/server-access.nix`.

The box runs Debian until the move to NixOS, so `deploy.sh` does not reach it
yet, and `scripts/affected-hosts.sh` prints it as `not-deployed`.

## Disk and boot

`disk.nix` is a disko layout for `/dev/vda`: a 1 MiB BIOS boot partition, an
ESP of 4 GiB at `/boot` (masks 0077 like the other hosts), and one ext4 root on
the rest.

The box boots through BIOS today, and the firmware setting stays. The record
sets `biosDevice = "/dev/vda"`, so Limine installs its BIOS stage on the disk
beside its EFI binary, and the same disk boots under UEFI too. BIOS has no
EFI variables to write, so `configuration.nix` sets
`boot.loader.efi.canTouchEfiVariables = false`. Limine then installs the EFI
binary at the firmware fallback path only. Any host that can boot through BIOS
sets it the same way.

## Access

`nixosModules/tailscale.nix` enables Tailscale on every host and keeps the
firewall closed except for tailscale0 and Tailscale's UDP port. A check fails the
evaluation when a host opens a port or trusts another interface. A server also
drops ping.

`nixosModules/server-access.nix` adds these to a server:

- Tailscale with its own SSH server (`--ssh`), an exit node, and IP forwarding
  (`useRoutingFeatures = "server"`).
- OpenSSH on 127.0.0.1:22 and on the tailnet address, port 2222. Port 22 on the
  tailnet address belongs to Tailscale SSH. The tailnet address is not in this
  repository, and it exists only while Tailscale is logged in. The unit
  `sshd-tailnet-listen` reads it from tailscaled every 10 seconds, writes it
  into `/run/sshd-tailnet.conf`, which `sshd_config` includes, and reloads
  sshd. Until then, such as on a node that is not logged in, sshd listens on
  loopback only.
- Root logs in by key, and only with the three keys in the module (Omer's shared
  key, the box's own key and the co-admin's). oruc keeps `~/.ssh/authorized_keys`
  on top of the declared key, because the Grok bots' login rewrites that file.
  `AllowUsers` lists root and oruc.

## Install

sops-nix decrypts `secrets/risoluto-dev-1.yaml` while the system activates,
with the age key of `/etc/ssh/ssh_host_ed25519_key`. The first boot needs that
key in place, because the network file and both password hashes come from the
file. An install that makes new host keys boots with no address and no
password. Install the Debian box's own key before the first boot, for example
with `nixos-anywhere --copy-host-keys`, and check that
`ssh-to-age < ssh_host_ed25519_key.pub` prints the `risoluto-dev-1` recipient of
`.sops.yaml`. `nixosModules/common.nix` lists the other hosts' keys in
`programs.ssh.knownHosts`; adding this one there changes every host's system, so
it waits for the move.

## Network and secrets

`secrets/risoluto-dev-1.yaml` has two recipients, Omer's shared key and the age
key of the box's SSH host key, as for the other hosts (`.sops.yaml`). Edit it
with `sops` as [Secrets](nixos-rog.md#secrets) describes. It holds the password
hashes of root and oruc (`neededForUsers`, so they exist before the users do)
and the public network: the IPv4 address with its prefix, the IPv4 gateway, the
IPv6 address with its prefix, and three resolvers.

`configuration.nix` renders those values into a systemd-networkd `.network` file
with `sops.templates`, so no address is in this public repository. sops-nix
renders it while the system activates, which on a boot runs before systemd
starts networkd. A switch that changes the file restarts networkd. The IPv4
gateway is on-link (`GatewayOnLink`), the IPv6 gateway is `fe80::1`, and router
advertisements are off.

## Boot test in a VM

`scripts/boot-server-vm-on-rog.sh` builds the host's disko image and boots it
twice, under SeaBIOS and under OVMF, each with QEMU's standard VGA. It runs on
nixos-rog, or on nixos-desktop while nixos-rog is offline, like the other
`-on-rog` scripts. The report came 13 to 15 seconds after the start under KVM
(observed on 2026-10-27); building the image the first time takes several
minutes. The script exits 1 unless the report matches the host: the firmware,
the units, the address and routes from the template, the users, the sshd
listeners and settings, the firewall, the sysctls, the disk layout and the swap,
journal and /tmp settings. It also exits 1 when the VGA screen is black 3
seconds after the start. Limine's menu is on the screen then (a dump on
2026-10-27 showed it under BIOS), but the check shows only that something was
drawn.

`ci/server-vm.nix` builds the image from the host with three changes. The sops
file holds test values under the real key names, encrypted for an SSH key that
the build makes. The disk is 16 GiB. The kernel also logs to the serial port,
and a test unit prints the state of the units, disk, users and network there,
then powers the VM off.

The test shows that the layout installs, that Limine boots from it under both
firmware types, that the units start, and that the template and the user
settings work with sops-nix's real activation. It does not show that the box's
own host key opens the real secrets file, that the netcup network works, that
Tailscale logs in, that sshd takes up a tailnet address (the report only shows
what the include adds), or that the BIOS stage installs from the kexec
installer.
`ci/checks.sh` only evaluates the image's system, so the boot test runs by hand
when the host, its disk or its boot loader changes.
