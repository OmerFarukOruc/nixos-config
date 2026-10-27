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

The box runs Debian until the move to NixOS, so no deploy goes to it yet. Its
record sets `deployed = false`, so `scripts/affected-hosts.sh` prints it as
`not-deployed`; remove the field at the move.

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

Two flake checks boot the host's own configuration with NixOS's VM test driver
(`ci/server-boot.nix`, disko's `makeDiskoTest`). `risoluto-dev-1-boot-bios`
boots under SeaBIOS and `risoluto-dev-1-boot-uefi` under OVMF. Both need KVM, so
they build on nixos-rog (or on nixos-desktop while nixos-rog is offline, as
`scripts/build-on-rog.sh` does):

```sh
scripts/build-on-rog.sh .#checks.x86_64-linux.risoluto-dev-1-boot-bios \
  .#checks.x86_64-linux.risoluto-dev-1-boot-uefi
```

The test installs the host's disk layout (`disk.nix`) and system from an
installer VM, including Limine's BIOS stage. It then reboots from that disk
without QEMU's kernel loader, so the firmware and Limine start the system. The
Python checks of `ci/server-boot/checks/` run last. They cover the units, the
address and routes from the sops template, the sshd listeners and settings, the
users, the firewall, the sysctls, the disk layout, and the swap, journal and
/tmp settings. A failed build prints the end of the driver's log, and
`nix log <derivation>` on that host prints all of it. Nix caches a pass until
the host or the test changes, and `ci/checks.sh` only evaluates both tests.

To add a check, put Python in a new file of `ci/server-boot/checks/`. The files
run in path order on `machine` (the booted host), `efi` is True under OVMF, and
all files share one Python namespace, so give a variable or a function a name
that only your file uses. Test values for a new sops key go in
`ci/server-boot/secrets.yaml`. A NixOS module that only the test machine loads,
such as a stub of an external service, goes in `ci/server-boot/modules/`.

`ci/server-boot/modules/sops.nix` gives the test machine a sops file with test
values under the real key names, encrypted for an SSH key that the build makes,
so sops-nix's real activation runs. The installer's disk is 16 GiB instead of
the box's 2 TiB, and the root partition takes the rest.

The test shows that the layout installs, that Limine boots from it under both
firmware types, that the units start, and that the template and the user
settings work with sops-nix's real activation. It does not show that the box's
own host key opens the real secrets file, that the netcup network works, that
Tailscale logs in, that sshd takes up a tailnet address, that `sshd_config`
includes the file with that address, or that the BIOS stage installs from the
kexec installer. It also does not cover the VGA console. QEMU gives the test
only a serial console and no guest agent channel, so `qemu-guest-agent` does
not start. The VM has 1 GiB of RAM instead of 62 GiB, and a 9p `/nix/store`,
which is disko's test wrapper.
