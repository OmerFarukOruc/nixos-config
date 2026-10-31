# devbox

- [What it is](#what-it-is)
- [Disk and boot](#disk-and-boot)
- [Access](#access)
- [Install](#install)
- [Network and secrets](#network-and-secrets)
- [Telemetry](#telemetry)
- [Deploys](#deploys)
- [Nightly update](#nightly-update)
- [Web names](#web-names)
- [Containers](#containers)
- [Agent runtime](#agent-runtime)
- [CLIProxyAPI](#cliproxyapi)
- [Streamed desktop](#streamed-desktop)
- [Memory and logs](#memory-and-logs)
- [Boot test in a VM](#boot-test-in-a-vm)
- [Deploy test in a VM](#deploy-test-in-a-vm)
- [What no test covers](#what-no-test-covers)
- [Streamed desktop CPU](#streamed-desktop-cpu)

## What it is

devbox is Omer's dev box, a netcup KVM guest with one 2 TiB virtio disk.
It is the first host with `kind = "server"` in `machines/inventory.nix`: no
login session, no workstation module, and the kernel from nixpkgs. Its files are
`machines/devbox/` (`configuration.nix`, `disk.nix`,
`hardware-configuration.nix`, `home.nix`) and `nixosModules/server-access.nix`.
The host imports four more modules for its services: `tailnet-web.nix`,
`rootless-containers.nix`, `agent-runtime.nix` and `envfs.nix`. Its record sets
`features.streamedDesktop`, which turns on `nixosModules/streamed-desktop.nix`
([Streamed desktop](#streamed-desktop)).

The box deploys itself ([Deploys](#deploys)), and the deploy rule of AGENTS.md
reaches it like the workstations.

## Disk and boot

`disk.nix` is a disko layout for `/dev/vda`, a GPT disk: a 1 MiB BIOS boot
partition (type EF02, which Limine's BIOS stage needs), an ESP of 4 GiB at
`/boot` (masks 0077 like the other hosts), and one ext4 root on the rest. The
ESP is 4 GiB as on the other hosts, because every kept generation stores a
kernel and an initrd on it. The firmware of a UEFI boot needs the ESP, so the
layout fits either firmware (`oruc.machine.biosDevice`), and only the BIOS boot
is tested.

The box boots through BIOS today, and the firmware setting stays. The record
sets `biosDevice = "/dev/vda"`, so Limine installs its BIOS stage on the disk
beside its EFI binary. The disk is meant to boot under UEFI too, but the VM
test boots it under BIOS only, so a UEFI boot is unverified. BIOS has no EFI
variables to write, so `configuration.nix` sets
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
  key, the box's own key and the co-admin's). omer keeps `~/.ssh/authorized_keys`
  on top of the declared key. Omer adds the Grok bots' key there by hand.
  `AllowUsers` lists root and omer.

## Install

sops-nix decrypts `secrets/devbox.yaml`,
`secrets/devbox-acme.yaml`, `secrets/devbox-github.yaml`,
`secrets/devbox-github-push.yaml`, `secrets/devbox-services.yaml` and
`secrets/devbox-cliproxy.yaml` while the system activates, with the
age key of `/etc/ssh/ssh_host_ed25519_key`. The first boot needs that key in
place, because the network file and both password hashes come from the first
file, the Cloudflare token for the certificates from the second, the deploy
unit's GitHub token from the third, and OpenChamber's passwords and the
herdr web UI's token from the fourth, and CLIProxyAPI's keys from the fifth
(`machines/devbox/services.nix`).
An install that makes new host keys boots with no address, no password, no
certificates and no deploy token. Install the Debian box's own key before the first boot, for example
with `nixos-anywhere --copy-host-keys`, and check that
`ssh-to-age < ssh_host_ed25519_key.pub` prints the `devbox` recipient of
`.sops.yaml`. `nixosModules/common.nix` lists the other hosts' keys in
`programs.ssh.knownHosts`; adding this one there changes every host's system, so
it waits for the move. `scripts/check-secrets.sh` without an argument checks
the sops files; with a file argument it compares only the main file.

## Network and secrets

`secrets/devbox.yaml` has two recipients, Omer's shared key and the age
key of the box's SSH host key, as for the other hosts (`.sops.yaml`). Edit it
with `sops` as [Secrets](nixos-rog.md#secrets) describes. It holds the password
hashes of root and omer (`neededForUsers`, so they exist before the users do)
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

### Rotate the box's token

The deploy unit ([Deploys](#deploys)) reads a fine-grained GitHub token,
`github-update-token`, so that Nix's GitHub fetches stay within the API limit
and `deploy.sh` can ask `gh` which pull request merged a running release. The
token has its own file, `secrets/devbox-github.yaml`, encrypted for the
same two recipients as the file above (`.sops.yaml`). GitHub lists the token as
"devbox self-deploy". It does not expire. Rotate it when it may have
leaked, in this order, so the box keeps a working token until the new one runs.
The steps apply after the move to NixOS:

1. Create the new token on GitHub (Settings, Developer settings, Fine-grained
   tokens). Set the repository access to this repository only, the permissions
   Contents and Pull requests to read-only, and no expiration.
2. From the repository root, write the token into the file without printing it.
   The command waits for the token on a hidden prompt. `jq -R` turns it into
   the JSON that `sops encrypt` reads from stdin, so it never appears in a
   process list. `sops encrypt` needs public keys only, so no password is
   asked:

   ```sh
   read -rs token && printf '%s' "$token" | jq -R '{"github-update-token": .}' | nix shell nixpkgs#sops -c sops encrypt --filename-override secrets/devbox-github.yaml --input-type json --output-type yaml /dev/stdin >secrets/devbox-github.yaml.new && mv secrets/devbox-github.yaml.new secrets/devbox-github.yaml; unset token
   ```

3. Land the file, then deploy it with `./deploy.sh devbox switch`, or
   wait for the timer. [deploy.md](deploy.md) has the rules.
4. On the box, run `sudo systemctl start self-deploy.service` and read
   `journalctl -u self-deploy`. The new token works when the run ends without a
   GitHub `401` error from Nix. When Nix reports `401`, the new token is wrong
   or lacks access to this repository. Skip step 5, create a corrected token,
   and repeat steps 2 to 4 with it.
5. Delete the old token on the same GitHub page.

After an edit, `scripts/check-secrets.sh` on the box decrypts every sops file
with the host key and compares their key names with the declared secrets.

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
  listed 16 patterns of infra units. The new box lists `caddy.service`,
  `acme-*.service`, `xrdp.service` and `xrdp-sesman.service`, and
  `nixosModules/deploy-host.nix` adds `self-deploy.service` and
  `self-deploy-reboot.service`, so each service that comes to the box later
  needs its unit in `journalUnits` before its lines ship.
  The lines of user units ship under the same `service.name` through
  `journalUserUnits`, which lists exact names, because a glob matches nothing
  there. This box lists `docker.service`. A line carries `_SYSTEMD_USER_UNIT`
  when the unit wrote it and `USER_UNIT` when the user's systemd wrote it about
  the unit, such as a start or the failure after a start limit, and both carry
  `_UID`. The receiver has no `--user-unit` option, and that option would read
  only the collector's own uid, so the module matches both fields. The
  collector reads the user journals (`user-<uid>.journal`) through the same
  `systemd-journal` group as the system journal.
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
collector on loopback (a sink that writes files). The check logs in as omer
over SSH, runs `sudo` to change a file under `/etc`, reads a secret as
`nobody`, which the `credstore` rule logs although the read fails, stops the
collector for a second login, and checks that the sink got each record after
the restart, the unit journal line, the info line of a user unit of omer and
the manager's line about it (not its debug line), and the host metrics. It proves that the
collector loads its config, that auditd loads the rules, and that the audit and
sshd records travel through the journal into the collector's pipeline and out
over OTLP. It does not prove TLS, the real endpoint, or
delivery to SigNoz, which the cutover proves.

## Deploys

After the move, the box keeps itself on `main`. `self-deploy.timer` runs
`./deploy.sh devbox switch` on the box every 2 hours, as root, with
deploy.sh's lock and rollback, and `self-deploy-reboot.timer` reboots at 02:10
UTC when the kernel or the initrd changed. The files are
`nixosModules/deploy-host.nix`, `nixosModules/deploy-unit.nix`, `scripts/self-deploy.sh` and
`scripts/self-deploy-reboot.sh`; [Self-deploy of a server](deploy.md#self-deploy-of-a-server)
has the details, the failure signal and how to pause the timer.

A deploy from nixos-desktop or nixos-rog logs in as root, not as omer, because
omer's sudo asks for a password (`deployLogin` in the machine record). The release
records of both kinds of deploy are in `/root/.local/state/nixos-config-deploy/`.
The long-running agent units of omer are in `oruc.deploy.sessionIgnore` in
`configuration.nix`. deploy.sh's session check leaves them out of a deploy as
omer. A deploy as root, which is every deploy above, checks only root's own
services.

## Nightly update

`nightly-update.timer` runs `scripts/nightly-update.sh` every night at 21:15
UTC, up to 10 minutes later, after Nix's garbage collection at 21:00 UTC
(midnight in the box's time zone). The script runs the steps of
[Update by hand](updates.md#update-by-hand) in a clone in
`/var/lib/nightly-update/repo`: it moves the apps, then the inputs, and commits
each move. The clone has no git hooks, so the script runs their commands
itself: `nix fmt` before each commit, then `ci/checks.sh`, `ci/unit-cycles.sh`
without import from derivation and `ci/build-hosts.sh`. A commit that fails
them is dropped. The build keeps each host's system as a link in
`/var/lib/nightly-update/roots`, so the garbage collection leaves the last
night's builds for the next run. The script pushes to `main` what passed. When `main` moved
during the run, it rebases and runs the checks again; a rebase conflict or a
push race leaves `main` alone until the next night. The module is
`nixosModules/nightly-update.nix`.

No VM check runs in the job, because devbox has no KVM (`/dev/kvm` is missing).
A kernel or initrd that it moves meets the 02:10 UTC reboot unchecked, and the
units its moves reach are checked only by the deploy
([What no test covers](#what-no-test-covers)). A run took 51 min 19 s on
2026-10-30 when the moved kernel needed its NVIDIA and sensor modules built for
nixos-desktop and nixos-rog, and 23 min 34 s on 2026-10-31 for a nixpkgs move
that reused the kept builds (`journalctl -u nightly-update`).

The unit runs as the system user `nightly-update` with a 4h30min limit. It
has no start window, and while it runs the 02:10 UTC reboot
([Deploys](#deploys)) waits for the next night. A run started in the minute
after the reboot unit scheduled a reboot is still stopped by that reboot. The timer
is not `Persistent`, because the box stays on and a missed night waits for the
next one.

A run that fails a step, or in which `prepare-update.sh` warns that a move
stays out, opens an issue labelled `nightly-update` with the title `Nightly update failed on main`,
or comments on it when it is open. The issue names each failed step with its
exit status and its error line; `journalctl -u nightly-update` has the full
log. A later run closes the issue when it fails no step, gets no warning from
`prepare-update.sh`, and pushes or finds nothing to move. A run that pushed
some moves while another failed comments instead.

Run it now with `sudo systemctl start nightly-update.service`. To run it on
another branch, run
`sudo systemctl set-environment NIGHTLY_UPDATE_BRANCH=<branch>` before the start
and `sudo systemctl unset-environment NIGHTLY_UPDATE_BRANCH` after it. Pause it
by masking `nightly-update.timer` in `/run/systemd/system.control` and stopping
it, as the [deploy unit](nixos-rog.md#deploy-unit) of nixos-rog shows, because a
deploy starts a stopped timer again and `systemctl mask --runtime` does not
mask a unit that NixOS keeps in `/etc/systemd/system`. Resume it by removing that link, running
`sudo systemctl daemon-reload` and `sudo systemctl start nightly-update.timer`.

The push and the issue calls use the fine-grained token `github-push-token` in
`secrets/devbox-github-push.yaml`, which GitHub lists as "devbox nightly
update". The run can read it the whole time, also while it evaluates the moved
inputs. A separate push unit would not narrow that, because the inputs that
pass reach devbox as root with the next deploy, and root reads the token.
Rotate it like [Rotate the box's token](#rotate-the-boxs-token), with these
changes:

- Step 1 sets Contents and Issues to read and write.
- Step 2 writes the other file and key:

  ```sh
  read -rs token && printf '%s' "$token" | jq -R '{"github-push-token": .}' | nix shell nixpkgs#sops -c sops encrypt --filename-override secrets/devbox-github-push.yaml --input-type json --output-type yaml /dev/stdin >secrets/devbox-github-push.yaml.new && mv secrets/devbox-github-push.yaml.new secrets/devbox-github-push.yaml; unset token
  ```

- Step 4 checks both permissions on the box without a run. A push with
  `--dry-run` of a new branch name asks GitHub for write access and creates
  nothing, and a label edit that keeps the label's color needs Issues write.
  The new token works when the command prints `[new branch]` and
  `nightly-update`; a `403` names the missing permission:

  ```sh
  sudo nix shell nixpkgs#git nixpkgs#gh -c bash -c 'export GH_TOKEN=$(</run/secrets/github-push-token); cd /var/lib/nightly-update/repo && git -c safe.directory="$PWD" -c credential.helper= -c "credential.helper=!gh auth git-credential" push --dry-run origin HEAD:refs/heads/nightly-update-token-check && gh api -X PATCH repos/OmerFarukOruc/nixos-config/labels/nightly-update -f color=d93f0b --jq .name'
  ```

## Web names

`nixosModules/tailnet-web.nix` serves the names of `oruc.tailnetWeb.sites` with
Caddy, for the tailnet. The host lists two: OpenChamber on 127.0.0.1:3000
and the herdr web UI on 127.0.0.1:7317. Each name has a public, DNS-only A
record to the tailnet address, kept outside this repository, so it resolves
everywhere and connects from the tailnet only.

- `security.acme` issues one Let's Encrypt certificate per name with the
  Cloudflare DNS-01 challenge. The token is `cloudflare-acme-dns-token` in
  `secrets/devbox-acme.yaml`, a second sops file with the same two
  recipients as the main one, because adding a value to the main file needs the
  shared key's passphrase. lego skips the check against the host's recursive
  resolvers (`--dns.propagation.disable-rns`), since the resolvers can keep
  answering NXDOMAIN for the challenge record until lego's time limit.
- Caddy listens on every address, with the NixOS module's own unit, so it needs
  no DNS and no tailnet address to start. The firewall opens no port on the
  public interface and trusts tailscale0 only, so the names answer from the
  tailnet alone; the boot test proves that a connection through the public
  interface is dropped.
- Every site removes the `Tailscale-User-Login` header. The herdr web UI trusts
  it on a request from loopback as the identity that `tailscale serve` sets,
  and every request Caddy forwards comes from loopback, so a client could
  forge it. The Debian Caddyfile strips it on the herdr site only;
  nothing behind the openchamber site reads it, so stripping it there changes
  no behaviour. Responses stream (`flush_interval -1`), and `grace_period 10s`
  (the Debian Caddyfile's value) keeps open event streams from holding a
  restart until systemd's stop timeout. A Caddy failure shows only in the
  journal, which reaches SigNoz without an alert; a config error exits with
  status 1, which the NixOS module never restarts.
- The admin API is off, so a change restarts Caddy and does not reload it.
- Caddy is ordered after the order units (`acme-order-renew-*`). Every
  order that installs a new certificate restarts Caddy (the module sets
  `reloadServices`), and the orders after the first run at the same time. An
  order that has copied its files but not yet run its `chmod` leaves a
  certificate and key that Caddy cannot read, so a restart in that window made
  Caddy exit with status 1 and stay down. A VM test with a test CA that held
  each order's `chmod` showed that exit in each run without this ordering; no
  check guards the ordering now. A failed order shows as `activating`, not in
  `systemctl --failed`, because its unit restarts after 15 minutes, and it
  leaves the self-signed certificate in place. A restart stops Caddy at once, and
  its start waits for the orders that run, so Caddy starts once they are done.
  The cost is that Caddy waits for the orders at boot, which begin after
  `network-online.target`, and is down while the last orders of a renewal
  finish. A deploy that restarts Caddy while an order runs waits for that
  order too, and `deploy.sh` rolls back a switch that takes longer than its
  420 second timer.
- NixOS retries a failed issuance every 15 minutes; the Debian box's lego
  timer ran daily. A wrong token fails at Cloudflare before Let's Encrypt
  validates anything, so the retries do not reach its limit for failed
  validations.

## Containers

`nixosModules/rootless-containers.nix` gives omer rootless Docker and rootless
Podman. omer is in no docker group, and the ranges in `/etc/subuid` and
`/etc/subgid` come from the host record.

- Docker is the NixOS `virtualisation.docker.rootless` unit. The socket is
  `$XDG_RUNTIME_DIR/docker.sock`, and `DOCKER_HOST` points at it in omer's
  shells. The daemon settings are the builder's garbage collection at 80 GB.
  `overlays/rootlesskit.nix` moves RootlessKit from 2.x to 3.3.0, the version
  Docker 29.9.1 ships, until nixpkgs has 3.0.0 or later. With 2.x, a
  connection to a published port could make the kernel kill dockerd and its
  containers. Docker picks the host port of a published container from
  32768-60999, and RootlessKit binds it on the host, where an outbound
  connection could already hold it. So `net.ipv4.ip_local_port_range` of the
  host is 61000-65535, which leaves 4535 ports per destination address and
  port for outbound connections. That this suffices is a guess; `ss -Htn state
  established | wc -l` on the Debian box printed 15 on 2026-10-27. The Debian
  box instead narrows Docker's range with a wrapper script. A port that a
  container publishes without an address listens on every address, so tailnet
  peers reach it, and the firewall blocks the public interface. If
  `docker.service` (a user unit) fails three times in 60 s it stays failed.
  `journalUserUnits` ships its journal lines at priority info and above to
  SigNoz, including the line of omer's systemd about the failure
  ([Telemetry](#telemetry)). The failure line is the signal an alert rule can
  use. The SigNoz alert rules live in statuslantern-scraper's
  `deploy/signoz/alerts/`, and none reads these lines yet. The rule waits for
  the first NixOS deploy to ship them, as for
  [self-deploy](deploy.md#self-deploy-of-a-server) failures, so until then
  only someone on the host sees the failed state.
- Podman has no daemon; the user unit `podman.socket` answers on
  `$XDG_RUNTIME_DIR/podman/podman.sock`. cliproxy's compose file reaches it with
  `DOCKER_HOST`, the docker CLI and its Compose plugin. `podman.service`, which
  the socket starts for each client, stops after 5 s without a request
  (`podman system service --time` default) and has no start limit
  (`StartLimitIntervalSec=0`), so a burst of failures does not block the next
  client's start. Its lines are not shipped.
- Rootful Docker, sysbox and iocost, which the Debian box has for its CI
  runners, stay out of the move, because the runners are dropped.

## Agent runtime

`nixosModules/agent-runtime.nix` holds what the agents run against.

- Playwright runs the nixpkgs browsers. `home-manager/modules/playwright.nix`
  sets `PLAYWRIGHT_BROWSERS_PATH` and `PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS`
  for omer, and the desktops import it too, so the browsers follow nixpkgs and
  nothing is pinned. A project's npm Playwright version must match
  `playwright-driver` in nixpkgs, as the
  [NixOS wiki](https://wiki.nixos.org/wiki/Playwright) says. A Chromium that
  Playwright downloads itself does not run on NixOS, so the agents must not
  call `playwright install`.
- envfs serves `/usr/bin` by the PATH of the caller. The units from the
  dotfiles checkout call `/usr/bin/zsh` and `/usr/bin/bash` with a PATH that
  holds nothing of NixOS, so the module adds `bash`, `zsh`, `systemctl` and
  `podman` to the fallback directory. The units find herdr, claude and the other
  profile tools through their PATH, which lists `/etc/profiles/per-user/%u/bin`,
  and coreutils such as `dirname` through `/run/current-system/sw/bin`, which
  the PATH also lists; there is no `/usr/local/bin` on this host, so a
  tool that only infra installed there (linctl, micro, lazygit, node and
  others) is missing until the profile or mise provides it.
- The Cursor worker's computer use drives XFCE on Xvnc, and the Amp runner
  drives labwc. The module installs both desktops with their NixOS modules, and
  the tools they call (tigervnc, xdotool, X utilities, ffmpeg, ImageMagick,
  wlr-randr, Chromium; Home Manager gives omer bubblewrap). Those two sessions
  start on demand, and the box has no login manager; xrdp starts a desktop for
  each RDP login ([Streamed desktop](#streamed-desktop)). The XFCE module
  also turns on udisks2, accounts-daemon, gvfs, tumbler, colord, polkit and
  gnome-keyring. Its screensaver is off, because it would lock the Cursor
  worker's session; the Debian box had none installed (`dpkg-query` for
  xfce4-screensaver, light-locker and xscreensaver on 2026-10-28). The boot
  test shows that these tools exist, not that an XFCE or labwc session starts.
- `features.boxBrowser` is on in the host record, so `box-browser` and its two
  user units exist ([box-browser.md](box-browser.md)).
- Home Manager gives omer the common layer and `home.nix`, which adds the
  hourly `desktop-sync.sh --config`, the Claude account tools of
  `pkgs/claude-tools` with their usage timer, and
  `claude-tools-limit-switch.timer` (next bullet).
- `claude-tools-limit-switch.timer` runs `claude-tools limit-switch scan` of
  `pkgs/claude-tools` every minute. A run starts herdr's default session through
  `herdr-default.service` when no server runs, starts the recorded Claude agents
  again after a server restart, and moves each named agent whose screen ends in
  a usage limit message to another account. A failed run means one agent could
  not move. The log names the agent and the reason:
  `journalctl --user -u claude-tools-limit-switch.service` and
  `~/.local/state/claude-tools/limit-switch/events.log`.
- `home.nix` also installs the agents' CLIs (`home-manager/modules/agent-cli.nix`,
  which brings worktrunk and the daily `worktree-sweep.timer` of
  [Claude Code and Codex setup](nixos-rog.md#claude-code-and-codex-setup),
  and the box's own list) and runs Omer's agent services as user services of
  omer: OpenChamber (`pkgs/openchamber-web.nix`, 127.0.0.1:3000), the herdr web
  UI (`pkgs/herdr-web-ui.nix`, 127.0.0.1:7317), herdr's default session, the
  Amp runner and the Cursor worker. An update by hand moves those packages
  like the others ([updates.md](updates.md#apps)). A deploy leaves a running
  OpenChamber, herdr session, Amp runner and Cursor worker alone
  (`X-SwitchMethod = "keep-old"`), so the new version starts at their next
  restart. Their secrets come from `services.nix`; after a secret changes,
  restart the user service, because sops-nix restarts only system units.
- `stay-green.timer` starts a run every 4 minutes around the clock. A run keeps
  Omer's Teams status Available on weekdays from 09:00 to 18:00 Istanbul time
  with `pkgs/stay-green.nix`, built from the `stay-green` flake input, and does
  nothing outside that schedule. The sign-in is in `~/.local/state/stay-green`. A
  failed run usually means the sign-in expired or was revoked; sign in again
  from a workstation with `stay-green login devbox`. Read a run with
  `journalctl --user -u stay-green.service -n 20`.

## CLIProxyAPI

`cliproxy.service`, a user unit of omer in `home.nix`, serves the Claude,
Codex, Gemini and Grok CLI logins as one OpenAI-compatible API on 127.0.0.1:8317.
It runs `machines/devbox/cliproxy/cliproxy-up.sh`, which starts the
compose stack of that folder on rootless Podman through the docker CLI
([Containers](#containers)). The unit owns the stack, so no container starts
before its config exists.

- The keys, the management key, the share node's `ts.net` name, its Tailscale
  auth key and the Cloudflare token are in `secrets/devbox-cliproxy.yaml`.
  sops-nix renders the app's config and an environment file from them
  (`services.nix`). `cliproxy.service` sets `CLIPROXY_RENDERED_CONFIG` and
  `CLIPROXY_DNS_TOKEN_FILE` to the rendered config and the Cloudflare token
  file, and passes `CLIPROXY_SHARE_HOST` and `CLIPROXY_TS_AUTHKEY` through its
  `EnvironmentFile`. The management panel can change the config, so
  `cliproxy-up.sh` gives the app a writable copy in `$XDG_RUNTIME_DIR/cliproxy`,
  which is tmpfs, and makes the copy again on every start. After a key changes, run
  `systemctl --user restart cliproxy.service`. A deploy that changes a file
  of the folder restarts the unit too, which stops the containers for the
  length of a start.
- The `share` profile adds `cliproxy-share`, a Tailscale container that joins
  the tailnet as its own node `cliproxy`, so a friend shared on that node reaches
  only the API. Its Serve config forwards port 443 as raw TCP to `tls-proxy`, a
  Caddy with the Cloudflare DNS provider that `cliproxy-up.sh` builds from
  `cliproxy/tls-proxy/`. Caddy serves the `ts.net` name with the certificate
  from the sidecar's tailscaled, and `cliproxy.risoluto.dev` with a Let's
  Encrypt certificate from the DNS-01 challenge.
- `cliproxy.risoluto.dev` (`CLIPROXY_PUBLIC_HOST` in `env.public`) is the share
  node's second name, beside its `ts.net` name (`CLIPROXY_SHARE_HOST`). It is a
  public, DNS-only A record at Cloudflare to the node's tailnet address, so it
  answers only on the tailnet. `cliproxy-up.sh` runs
  `cliproxy/dns-record.sh apply` after every start and update; the script
  changes only that one record. To see what it would do, run
  `"$(dirname "$(systemctl --user show -p ExecStart --value cliproxy.service | grep -o '/nix/store/[^ ;]*cliproxy-up.sh')")"/dns-record.sh plan`
  on the box.
- `cliproxy-update.timer` reloads the unit daily at 04:30 Istanbul time. The
  reload pulls the CLIProxyAPI and Tailscale images, rebuilds `tls-proxy`, and
  recreates the containers whose image changed.
- OAuth token files stay in `~/.local/state/fleet/cliproxy/auths`, because the
  app owns that store. The logs, the sidecar's Tailscale state and Caddy's
  certificates are under `~/.local/state/fleet/cliproxy` too.
- A provider's OAuth login in the panel redirects to a callback port on
  127.0.0.1 of the box (8085, 1455, 54545, 51121 or 11451, by provider).
  Forward that port from a workstation before the login, for example
  `ssh -N -L 1455:127.0.0.1:1455 omer@devbox`.

## Streamed desktop

`features.streamedDesktop` of the record turns on
`nixosModules/streamed-desktop.nix`: a light XFCE desktop for omer, which Omer
reaches from another machine over the tailnet through xrdp. A server with this
feature has no login session in its record; `sessions.hasGraphicalUser` (`machines/sessions.nix`) tells the modules
that give a graphical user fonts, a browser and the keyboard layout to apply
([Inventory](architecture.md#inventory)).

- **xrdp.** Each RDP login of omer starts a desktop of its own on an X server
  with the xorgxrdp driver, and a reconnect finds the same session again
  (sesman keeps a disconnected session). Nothing runs before the first login:
  the box has no display manager, and the netcup console keeps its login on
  tty1. `overlays/xrdp.nix` builds xrdp with x264, because nixpkgs builds it
  without an H.264 encoder; xrdp's own `gfx.toml` then prefers H.264, and a
  client that asks for it (FreeRDP's `/gfx:AVC420`) gets it.
- **Keyboard.** The session takes the keyboard layout that the client sends
  with the login. xrdp 0.10.6.1 has no map for the Turkish Q layout, so
  `overlays/xrdp.nix` adds the two patches from xrdp's v0.10 branch that map
  it to X's `tr`.
- **Session bus.** The session runs under `dbus-run-session`. sesman starts a
  second session for omer when a client asks for another color depth
  (`Policy=Default` in its `sesman.ini`), and a second `xfce4-session` on
  omer's systemd user bus ends at once. The Cursor worker and the Amp runner
  start their own XFCE and labwc sessions, each on a session bus of its own
  (`dbus-launch` and `dbus-run-session`, read from the Debian box on
  2026-10-27).
- **Nothing on the public interface.** xrdp opens no firewall port. It answers
  on tailscale0, which the firewall trusts, and the assertion of
  `nixosModules/tailscale.nix` fails the evaluation when a port gets opened.
  xrdp listens on every address, as sshd does, so the firewall is the only
  guard.
- **First use.** The workstations have Remmina
  (`home-manager/profiles/workstation.nix`): open its `devbox` profile and log
  in as omer with omer's password, the one `sudo` asks for on devbox (the hash
  is in `secrets/devbox.yaml`). A Home Manager step writes that profile with
  dynamic resolution, so the desktop follows the window size. Without it, a
  quick connect from nixos-desktop on 2026-10-30 kept the size Remmina read
  from its window before the window mapped, 644x480. The profile shares the
  PC's home folder, which appears on devbox under `~/thinclient_drives` while
  the session runs, where devbox's agents can read and write it too, and asks
  for the session's sound (the Audio bullet below). The step also sets
  Remmina's RDP keyboard layout to Turkish Q. Remmina's default colour depth
  ("Automatic") gets H.264 from xrdp.
- **Scale.** Remmina on Wayland is drawn at a whole-number scale that KWin
  resamples to a fractional Plasma scale, so devbox's desktop looks soft.
  Under Plasma, Remmina's wrapper starts it on X11 at the whole-number scale
  nearest to Xft.dpi divided by 96, and sets `GDK_DPI_SCALE` so its own text
  keeps Plasma's size. nixos-desktop (1.7) gets 2: a maximized window gave a
  1876x979 desktop on 2026-10-30, and Omer found it sharper than the Wayland
  window. nixos-rog (1.25) gets 1, so Remmina's icons and devbox's desktop
  draw at 80% of Plasma's size, one remote pixel per screen pixel. Under niri
  Remmina stays on Wayland. Setting `GDK_BACKEND` before the start skips the
  wrapper. Remmina runs one instance, so a running Remmina keeps its backend;
  quit it (`remmina --quit`) before a start that should change it.
- **Network.** The tailnet policy, in the Tailscale admin console, grants TCP
  3389 on devbox to nixos-desktop (`tag:desktop-relay`); nixos-rog and
  nixos-latitude reach it as Omer's own devices, through the grant that lets
  members reach every device.
- **Remmina check.** A run in a NixOS VM on 2026-10-28 with
  Remmina 1.4.43 as the client showed the `tr` layout, H.264, ı, ş and ğ, and
  pointer moves that reach the desktop at once. sesman refuses root logins,
  which it allows by default. The XFCE screensaver is off, because the login
  and every reconnect ask for the password already.
- **Logs.** xrdp's logs go to the journal, where the NixOS module sends them to
  `/dev/null`, and `journalUnits` lists `xrdp.service` and
  `xrdp-sesman.service`.
- **Audio.** PipeWire runs on the box, because `programs.labwc` of the agent
  runtime turns on nixpkgs' `services.graphical-desktop`, which turns PipeWire
  on. nixpkgs' `services.xrdp.audio` loads only a PulseAudio module, so
  `pkgs/pipewire-module-xrdp.nix` packages xrdp's PipeWire module, and
  `/etc/xdg/autostart/pipewire-xrdp.desktop` runs its `load_pw_modules.sh`
  when XFCE starts in an xrdp session. The script ends the `pw-cli` process
  that held the module for the previous login, starts a new one that adds the
  `xrdp-sink` and `xrdp-source` nodes, and makes them the defaults. It also
  forces a PipeWire quantum of 2048 samples. That `pw-cli`, the default nodes
  and the quantum stay after a logout until the next login or a PipeWire
  restart, and they apply to every PipeWire client of omer. A client hears the
  sound when it asks for it, as Remmina's `devbox` profile does
  (`sound=local`). During a session,
  `wpctl inspect @DEFAULT_AUDIO_SINK@ | grep node.name` on the box prints
  `xrdp-sink`.
- **Why not Sunshine.** Sunshine with Moonlight was the other route. In the
  NixOS VM test of 2026-10-27 that measured both, on 4 cores of nixos-desktop, the whole VM used 0.99
  cores on an idle desktop with Moonlight connected and 0.08 with an RDP
  client, and 1.62 and 0.84 while playing a 1080p video. Sunshine also needs an
  X session logged in as omer from boot, with no screen lock.

## Memory and logs

The host sets zram swap of 16 GiB, `vm.swappiness` 100 and journald's cap at 2
GiB, each over the shared value. The host has no systemd-oomd swap kill,
because `nixosModules/memory.nix` sets it on `app.slice` of the workstations
only. `/tmp` stays on the disk, loses files untouched for 7 days, and
keeps `/tmp/tmux-*`, `/tmp/.X11-unix` and `/tmp/.ICE-unix`.

## Boot test in a VM

The flake check `devbox-boot-bios` boots the host's own configuration
with NixOS's VM test driver (`ci/server-boot.nix`, disko's `makeDiskoTest`)
under SeaBIOS, the firmware the netcup box boots with (it has no
`/sys/firmware/efi`). It needs KVM, so it builds on the host that runs
`scripts/build.sh`:

```sh
scripts/build.sh .#checks.x86_64-linux.devbox-boot-bios
```

The test installs the host's disk layout (`disk.nix`) and system from an
installer VM, including Limine's BIOS stage. It then reboots from that disk
without QEMU's kernel loader, so the firmware and Limine start the system. The
Python checks of `ci/server-boot/checks/` run last. They wait for sshd,
tailscaled, systemd-networkd, getty, Caddy and the telemetry units, and cover the
address and routes from the sops template, the sshd listeners and settings, the
users, the firewall, the sysctls, the disk layout, and the swap, journal and
/tmp settings. The telemetry check ([Telemetry](#telemetry)) covers the
collector and auditd. A connection from outside the VM to port 2222 must get no
answer, and must get sshd's banner once the test opens that port. A failed
build prints the end of the driver's log, and `nix log <derivation>` on that
host prints all of it. Nix caches a pass until the host or the test changes,
and `ci/checks.sh` only evaluates the test.

To add a check, put Python in a new file of `ci/server-boot/checks/`. The files
run in path order on `machine` (the booted host), and all files share one
Python namespace, so give a variable or a function a name that only your file
uses. Test values for a new sops key go in
`ci/server-boot/secrets.yaml`. A NixOS module that only the test machine loads,
such as a stub of an external service, goes in `ci/server-boot/modules/`.

`ci/server-boot/modules/sops.nix` gives the test machine a sops file with test
values under the real key names, encrypted for an SSH key that the build makes,
so sops-nix's real activation runs. The installer's disk is 16 GiB instead of
the box's 2 TiB, and the root partition takes the rest.

`ci/server-boot/modules/services.nix` and `ci/server-boot/checks/20-services.py`
cover the web names, the containers and the agent runtime. Caddy starts with
its config and answers the host's names with test certificates, and the
firewall drops a connection to port 443 from outside. A forged
`Tailscale-User-Login` does not reach any backend. Docker and Podman answer as
omer through their user sockets, a port that Docker publishes lies outside the
host's outbound range and answers, to a client on loopback and to a client at
the host's own global address, and a busybox image that the build puts on
the disk runs under both. The second client stands for a tailnet peer. RootlessKit 3
tries to keep the source address of a client that is not on loopback
(`--source-ip-transparent`, on by default), and never tries it for a loopback
client. `box-browser status` passes, and the Chromium of
nixpkgs' Playwright, found through omer's session variables, loads a local page
headless.

The test shows that the layout installs, that Limine boots from it under BIOS,
that the units start, and that the template and the user
settings work with sops-nix's real activation. It does not show that the box's
own host key opens the real secrets files, that the netcup network works, that
Tailscale logs in, that a tailnet peer reaches sshd, that CLIProxyAPI and
stay-green start (they need a registry and a Teams sign-in, so the test turns
them off and checks their secrets only), that Let's Encrypt issues the host's certificates with the real
Cloudflare token, or that the BIOS stage installs from the kexec installer. The
cutover proves the real certificates and the tailnet address. It also does
not cover the VGA console. QEMU gives the test only a serial console and no
guest agent channel, so `qemu-guest-agent` does not start. The VM has 1 GiB of RAM instead of 62 GiB,
and a 9p `/nix/store`, which is disko's test wrapper.

`configuration.nix` sets `services.smartd.enable = false`, because smartd
failed to start in a VM test (`smartd.service: Failed with result 'exit-code'`)
on a virtio disk, the kind this host has, and `nixosModules/monitoring.nix`
enables smartd unless a host says otherwise.

## Deploy test in a VM

The flake check `devbox-self-deploy` (`ci/self-deploy.nix`) is a NixOS
test of the deploy path of [Deploys](#deploys), and it needs KVM like the boot
tests. Run it with
`scripts/build.sh .#checks.x86_64-linux.devbox-self-deploy`. It
is not part of the boot test, because disko's test machine mounts a read-only
`/nix/store` that a deploy cannot write to.

The node is named devbox and loads `nixosModules/upgrade.nix`,
`nixosModules/deploy-host.nix` and `nixosModules/telemetry.nix` (whose option the
second one sets), not the host's whole configuration. Its ESP is
a 4 GiB second disk with Limine, because `deploy.sh` wants 1 GiB of free space
there and qemu-vm's own ESP has 256 MiB. Three specialisations of the node are
the systems to deploy: a good one, one whose sshd fails to restart, and one
with another initrd. The VM has no network, so a local repository stands for
GitHub, and each main in it holds a test flake that answers for the host with
the store path of one specialisation. `ci/self-deploy/test.py` holds the
checks. They start `self-deploy.service` against a good main, the same main
again, a main that breaks sshd (the previous system returns, the unit fails and
the next run waits for main to move) and a main with another initrd (the reboot
unit schedules a reboot, and waits while a deploy holds the lock or a nightly
update runs) and a main
whose evaluation cannot download an input (the unit fails, records no failed
main, and the next main deploys). They also check the timer calendars, the
ignore list of the session check, omer's sudo password, the boot entries on the
ESP and the private Nix config that a test token becomes.

The test does not show that a deploy over SSH as root reaches the box, that the
box fetches the real main from GitHub, that the real flake evaluates (the boot
tests and `ci/checks.sh` do), or that a deployed system boots; it never reboots.

## What no test covers

A deploy rolls back when a system unit fails during the switch or root's
session check fails ([Deploys](#deploys)). After a deploy, run `systemctl
--failed` and `systemctl --user -M omer@ --failed` on the box. These show only
in daily use:

- **omer's user units.** A root deploy checks only root's own services, so a
  failed Home Manager unit of omer, such as cliproxy, rolls nothing back.
- **Units that keep their old version.** OpenChamber, herdr, the Amp runner and
  the Cursor worker set `X-SwitchMethod = "keep-old"` in
  `machines/devbox/home.nix`, so a deploy does not start their new version.
- **Quoted environment values.** stay-green's schedule is quoted in
  `machines/devbox/home.nix`; without the quotes systemd splits the value at a
  space, and no unit fails.
- **ACME orders.** A failed order shows as `activating`
  ([Web names](#web-names)), and nothing checks that Caddy starts after the
  orders; Caddy down after a renewal shows it.
- **The streamed desktop.** H.264 from xrdp (`overlays/xrdp.nix`), the `tr`
  layout, the reconnect to the same session, and the desktop that starts only
  at the first login show at the next RDP login. A patch that stops applying
  fails the build.
- **A unit that fails only at boot.** Nothing rolls back after the 02:10 UTC
  reboot.

## Streamed desktop CPU

A NixOS VM test on nixos-desktop measured the streamed desktop on 2026-10-28.
These are VM numbers: the VM had 4 cores of nixos-desktop's CPU, not the netcup
box's. Each cell is the average busy cores over 30 seconds, from
`/proc/stat`. The load ran in the VM itself as
omer, in the RDP session: Chromium on a 20000-line text page that a script scrolls,
and Chromium on a 20 s looping 1080p VP9 video, a synthetic test pattern that
Chromium decodes in software on a host with no GPU. The client asks for H.264 at
1920x1080 (`/gfx:AVC420`) and gets x264 from xrdp.

| Load | whole VM | `xrdp` process | `Xorg` of the session |
| ---- | -------- | -------------- | --------------------- |
| idle desktop | 0.06 | under 0.01 | under 0.01 |
| scrolling page | 0.83 | 0.18 | 0.13 |
| video 1080p | 0.75 | 0.15 | 0.07 |

The measurement listed the six busiest processes, and on the idle desktop neither
`xrdp` nor `Xorg` was among them, behind processes at 0.00. Chromium itself
used 0.37 cores while scrolling and 0.42 while playing video.
The host's steal time (CPU that the host took from the VM) was at most 0.01
cores in that run; a busy host gives other numbers.
