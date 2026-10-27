# risoluto-dev-1

- [What it is](#what-it-is)
- [Disk and boot](#disk-and-boot)
- [Access](#access)
- [Install](#install)
- [Network and secrets](#network-and-secrets)
- [Telemetry](#telemetry)
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
- OpenSSH on port 2222, on every address, as the workstations run it with
  `openFirewall = false` (`nixosModules/ssh.nix`). The firewall drops port 2222
  on the public interface and accepts everything on tailscale0, so only the
  tailnet reaches sshd. Port 22 on the tailnet address belongs to Tailscale SSH.
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
IPv6 address with its prefix, and three resolvers. Passwords change only in
this file, because `users.mutableUsers` is false and a `passwd` on the box is
lost at the next activation.

`configuration.nix` renders those values into a systemd-networkd `.network` file
with `sops.templates`, so no address is in this public repository. sops-nix
renders it while the system activates, which on a boot runs before systemd
starts networkd. A switch that changes the file restarts networkd. The IPv4
gateway is on-link (`GatewayOnLink`), the IPv6 gateway is `fe80::1`, and router
advertisements are off.

## Telemetry

`nixosModules/telemetry.nix` is for every server. `oruc.telemetry.enable` turns
it on, and the host passes its environment name, the endpoint, and the units
to ship (`configuration.nix` does this for this box).
The host name defaults to `networking.hostName`. The module holds no host value.

It runs one OpenTelemetry collector, the contrib build, as
`opentelemetry-collector.service`, plus `auditd`. The collector exports over
gRPC with TLS to the central endpoint (SigNoz) and keeps its queue and the
journal cursors under `/var/lib/opentelemetry-collector`, so a restart or an
outage loses nothing that the retry window covers.

- **Metrics** every 60 s: CPU, disk, filesystem, load, memory, network (without
  `veth`, `br-` and `docker` interfaces), paging, processes and system, the
  collector's own metrics, and the `/tmp` mount when `filesystemMounts` names
  it. `/tmp` is not a mount on the Debian box today (observed on 2026-10-27),
  so the Debian collector reported nothing for it. The VM test runs that
  receiver but does not check its output.
- **OTLP** on `127.0.0.1:4318` (HTTP) for host processes. Metrics and traces
  carry `host.id`, `host.name` and `deployment.environment.name`.
- **Logs**, retried without a time limit. `service.name=host-audit` holds the
  sshd journal and the audit records, from the start of the journal on a first
  start. `service.name=infra-units` holds the lines of `journalUnits` at
  priority info and above, from the end of the journal on a first start. The
  name keeps the old one so existing SigNoz queries match. The Debian box
  listed 16 patterns of infra units. The new box lists `caddy.service` and
  `acme-*.service`, so each service that comes to the box later needs its unit
  in `journalUnits` before its lines ship.
- The endpoint is a public DNS name that resolves to a tailnet address, so it
  answers only on the tailnet. It is a plain option and no secret.

The module also sets sshd's `LogLevel` to `VERBOSE`, which is what the Debian
box logs at. `Accepted publickey` carries the key's fingerprint at the default
level too.

**Audit rules** are in `security.audit.rules`. They keep the keys that SigNoz
shows today, ported to NixOS paths:

| Key | Watches |
| --- | --- |
| `unit-change` | `/etc/systemd` |
| `sudo-change` | `/etc/sudoers` |
| `ssh-config` | `/etc/ssh` |
| `audit-config` | `/etc/audit` |
| `identity` | `/etc/passwd`, `/etc/shadow`, `/etc/group` |
| `etc-change` | `/etc`, by a login session only |
| `sudo-exec` | execution of `/run/wrappers/bin/sudo` |
| `credstore` | `/run/secrets.d` (sops-nix): writes, and reads by a user other than root |

The Debian watches of `/usr/lib/systemd/system`, `/etc/sudoers.d`,
`/etc/credstore.encrypted` and `/var/lib/systemd/credential.secret` are gone.
The first three paths do not exist on NixOS, and the fourth exists only after
something uses `systemd-creds` with the host key. A rule whose path does not
exist fails to load and stops the rules after it. A file
created in `/etc/sudoers.d` still logs as `etc-change`. The first matching rule
decides, so the specific rules come first and the three excludes (network,
promiscuous mode and BPF records of processes with no login session) come last.
`audit-rules-nixos` loads the rules again whenever the sudo wrapper changes,
because a rule follows the file it saw at load.

The audit records reach the journal through auditd's syslog plugin
(`SYSLOG_IDENTIFIER=audisp-syslog`), and `systemd-journald-audit.socket` is off.
Records that journald reads from that socket have no `PRIORITY`, and the
collector's journald receiver always passes `--priority`, so it would never ship
them.

Changes from the Debian setup. One collector replaces the two there, because on
NixOS it reads the journal through the `systemd-journal` group and needs no
chroot. Health checks and self-metrics use `127.0.0.1:13133` and
`127.0.0.1:8888`. The filters that dropped the start and stop records of
`sysbox-fuse-watchdog`, `infra-reconcile@infra` and `fleet-bots-pin`, and the
watchdog's run lines, are gone with those units. systemd sends a
`SERVICE_START` and a `SERVICE_STOP` record for every unit start, and the
collector now ships all of them. A unit that starts often, such as the deploy
timer, adds noise. Add a filter when SigNoz shows it.

The boot test covers it in `ci/server-boot/checks/10-telemetry.py`. Its module
`ci/server-boot/modules/telemetry.nix` points the collector at a second
collector on loopback (a sink that writes files). The check logs in as oruc
over SSH, runs `sudo` to change a file under `/etc`, reads a secret as
`nobody`, which the `credstore` rule logs although the read fails, stops the
collector for a second login, and checks that the sink got each record after
the restart, the unit journal line, and the host metrics. It proves that the
collector loads its config, that auditd loads the rules, and that the audit and
sshd records travel through the journal into the collector's pipeline and out
over OTLP. It does not prove TLS, the real endpoint, or
delivery to SigNoz, which the cutover proves.

## Boot test in a VM

Two flake checks boot the host's own configuration with NixOS's VM test driver
(`ci/server-boot.nix`, disko's `makeDiskoTest`). `risoluto-dev-1-boot-bios`
boots under SeaBIOS and `risoluto-dev-1-boot-uefi` under OVMF. Both need KVM, so
they build on the host that runs `scripts/build.sh`:

```sh
scripts/build.sh .#checks.x86_64-linux.risoluto-dev-1-boot-bios \
  .#checks.x86_64-linux.risoluto-dev-1-boot-uefi
```

The test installs the host's disk layout (`disk.nix`) and system from an
installer VM, including Limine's BIOS stage. It then reboots from that disk
without QEMU's kernel loader, so the firmware and Limine start the system. The
Python checks of `ci/server-boot/checks/` run last. They cover the units, the
address and routes from the sops template, the sshd listeners and settings, the
users, the firewall, the sysctls, the disk layout, and the swap, journal and
/tmp settings. The telemetry check ([Telemetry](#telemetry)) covers the
collector and auditd. A connection from outside the VM to port 2222 must get no
answer, and must get sshd's banner once the test opens that port. A failed
build prints the end of the driver's log, and `nix log <derivation>` on that
host prints all of it. Nix caches a pass until the host or the test changes,
and `ci/checks.sh` only evaluates both tests.

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
Tailscale logs in, that a tailnet peer reaches sshd, or that the BIOS stage
installs from the kexec installer. It also does not cover the VGA console. QEMU
gives the test only a serial console and no guest agent channel, so
`qemu-guest-agent` does not start. The VM has 1 GiB of RAM instead of 62 GiB,
and a 9p `/nix/store`, which is disko's test wrapper.
