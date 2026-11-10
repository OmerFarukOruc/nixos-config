# devbox

- [What it is](#what-it-is)
- [Disk and boot](#disk-and-boot)
- [Access](#access)
- [Install](#install)
- [Network and secrets](#network-and-secrets)
- [Telemetry](#telemetry)
- [AWS certificate](#aws-certificate)
- [Deploys](#deploys)
- [Web names](#web-names)
- [Containers](#containers)
- [Agent runtime](#agent-runtime)
- [Factory run user](#factory-run-user)
- [CLIProxyAPI](#cliproxyapi)
- [Streamed desktop](#streamed-desktop)
- [Memory and logs](#memory-and-logs)
- [Boot test in a VM](#boot-test-in-a-vm)
- [What no test covers](#what-no-test-covers)
- [Streamed desktop CPU](#streamed-desktop-cpu)

## What it is

devbox is Omer's dev box, a netcup KVM guest with one 2 TiB virtio disk.
It is the first host with `kind = "server"` in `machines/inventory.nix`: no
login session, no workstation module, and the kernel from nixpkgs. Its files are
`machines/devbox/` (`configuration.nix`, `disk.nix`,
`hardware-configuration.nix`, `home.nix`, `services.nix` and the `cliproxy/`
folder of the CLIProxyAPI containers) and `nixosModules/server-access.nix`.
The host imports four more modules for its services: `tailnet-web.nix`,
`rootless-containers.nix`, `agent-runtime.nix` and `envfs.nix`. Its record sets
`features.streamedDesktop`, which turns on `nixosModules/streamed-desktop.nix`
([Streamed desktop](#streamed-desktop)).

The box installs `main` by itself ([Deploys](#deploys)), and the deploy rule of AGENTS.md
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
drops ping. Rootful Docker on a workstation forwards a published port with its
own nftables rules, which `networking.firewall` does not filter, so
`nixosModules/docker.nix` binds a published port to 127.0.0.1 unless the
container names an address, as `-p 0.0.0.0:8080:80` does. `ip` sets that for
the default bridge and `default-network-opts` for each user-defined network,
such as a Compose project's, made after the setting. A network made before it
keeps 0.0.0.0 until `docker compose down` or `docker network rm` removes it.

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
`secrets/devbox-acme.yaml`,
`secrets/devbox-services.yaml` and
`secrets/devbox-cliproxy.yaml` while the system activates, with the
age key of `/etc/ssh/ssh_host_ed25519_key`. The first boot needs that key in
place, because the network file and both password hashes come from the first
file, the Cloudflare token for the certificates from the second, the
OpenChamber and OpenCode server passwords, the herdr web UI's token and the
Infisical Agent's client id, client secret and project id from the third, and CLIProxyAPI's keys, its Cloudflare DNS token, its Tailscale auth key
and its share host from the fourth. `machines/devbox/services.nix` declares the
secrets of the last two files. On the box, `sudo` with that key decrypts and
edits all four without Omer's key. Neither `sops` nor `ssh-to-age` is on the
box's PATH, so build them as `scripts/check-secrets.sh` does
(`nix build --no-link --print-out-paths nixpkgs#sops nixpkgs#ssh-to-age`), pass
`SOPS_AGE_KEY_CMD="<ssh-to-age> -private-key -i /etc/ssh/ssh_host_ed25519_key"`
to `sops`, and give `sops set` the value with `--value-file`, so it never sits
on a command line.
An install that makes new host keys boots with no address, no password and no
certificates. Install the Debian box's own key before the first boot, for example
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

## Telemetry

`nixosModules/telemetry.nix` is for every server. `oruc.telemetry.enable` turns
it on, and the host passes its environment name and the endpoint
(`configuration.nix` does this for this box).
The host name defaults to `networking.hostName`. The module holds no host value.

It runs one OpenTelemetry collector, the contrib build, as
`opentelemetry-collector.service`, plus `auditd`. The collector exports metrics
over gRPC to the central endpoint (SigNoz) without TLS (`insecure = true`),
because the gateway's receiver has none and WireGuard encrypts the traffic
between the tailnet nodes. Status Lantern's tailnet policy opens the gateway's
`tcp:4317` to this box through the grant from `tag://personal/infra-agent`
(Status Lantern `docs/observability.md`, Paths). The collector keeps its queue
under `/var/lib/opentelemetry-collector`. The exporter's queue holds at most
256 MiB on disk (`queue_size`, by bytes), so a restart or an outage loses
nothing that fits in it and in the retry window. While the export fails, a full
queue drops new records.

- **Metrics** every 60 s: CPU, disk, filesystem, load, memory, network (without
  `veth`, `br-` and `docker` interfaces), paging, processes and system, the
  collector's own metrics, and the `/tmp` mount when `filesystemMounts` names
  it. `/tmp` is not a mount on the Debian box today (observed on 2026-10-27),
  so the Debian collector reported nothing for it. The VM test runs that
  receiver but does not check its output.
- **Certificates** every hour: `tlscheck.time_left` for each file in
  `certificates`. This box lists its IAM Roles Anywhere certificate,
  `~/.aws/rolesanywhere/leaf.pem` of omer, which the AWS profile
  `statuslantern` signs with. Status Lantern's SigNoz rule `devbox AWS
  certificate expiring or missing` (`signoz/rules/devbox-certificate.json` in
  that repository) posts to Slack when the certificate has under 30 days left
  or its metric is missing for 2 hours, with the renewal steps of [AWS
  certificate](#aws-certificate). systemd
  hands the collector a copy of each file (`LoadCredential`, with an empty
  `SetCredential` default), so a missing file only makes that receiver
  report a scrape error. `opentelemetry-collector-certificates.path` reloads
  the copies when a file changes, such as at a renewal, without a restart
  (`RefreshOnReload=credentials`). The VM test checks that the metric of its
  own test certificate reaches the sink.
- **OTLP** on `127.0.0.1:4318` (HTTP) for the metrics of host processes. Every
  metric carries `host.id`, `host.name` and `deployment.environment.name`.
- **Logs** do not leave the box. The module has no log pipeline, so the sshd
  lines, the audit records and every unit's lines stay in the journal, where
  `journalctl` reads them.
- The endpoint is a public DNS name that resolves to a tailnet address, so it
  answers only on the tailnet. It is a plain option and no secret.

The module also sets sshd's `LogLevel` to `VERBOSE`, which is what the Debian
box logs at. `Accepted publickey` carries the key's fingerprint at the default
level too.

**Audit rules** are in `security.audit.rules`. They keep the keys of the Debian
box, ported to NixOS paths:

| Key | Watches |
| --- | --- |
| `unit-change` | `/etc/systemd` |
| `sudo-change` | `/etc/sudoers` |
| `ssh-config` | `/etc/ssh` |
| `audit-config` | `/etc/audit` |
| `identity` | `/etc/passwd`, `/etc/shadow`, `/etc/group` |
| `etc-change` | `/etc`, by a login session only |
| `sudo-exec` | execution of the store `sudo` binary, which `/run/wrappers/bin/sudo` and `sudoedit` start |
| `credstore` | `/run/secrets.d` (sops-nix): writes, and reads by a user other than root |

The Debian watches of `/usr/lib/systemd/system`, `/etc/sudoers.d`,
`/etc/credstore.encrypted` and `/var/lib/systemd/credential.secret` are gone.
The first three paths do not exist on NixOS, and the fourth exists only after
something uses `systemd-creds` with the host key. A rule whose path does not
exist fails to load and stops the rules after it. A file
created in `/etc/sudoers.d` still logs as `etc-change`. The first matching rule
decides, so the specific rules come first and the three excludes (network,
promiscuous mode and BPF records of processes with no login session) come last.
The `sudo-exec` rule watches the store binary instead of the wrapper, because
each switch recreates `/run/wrappers` and the kernel drops a watch whose path
goes away.

The audit records reach the journal through auditd's syslog plugin
(`SYSLOG_IDENTIFIER=audisp-syslog`), and `systemd-journald-audit.socket` is off.

Changes from the Debian setup. One collector replaces the two there. Health
checks and self-metrics use `127.0.0.1:13133` and `127.0.0.1:8888`.

The boot test covers it in `ci/server-boot/checks/10-telemetry.py`. Its module
`ci/server-boot/modules/telemetry.nix` points the collector at a second
collector on loopback (a sink that writes files). The check restarts
`suid-sgid-wrappers` and checks that the `sudo-exec` rule stays, that auditd
loads the rules, that sshd logs at `VERBOSE`, that the sink gets the host
metrics and the test certificate's `tlscheck.time_left`, that a journal line
with the audit identifier is not in the sink's log file 15 seconds later, and
that the collector's journal has no `error` line. It does not prove the real
endpoint or delivery to SigNoz.

## AWS certificate

The AWS profile `statuslantern` signs with the IAM Roles Anywhere certificate
`~/.aws/rolesanywhere/leaf.pem` of omer. The role `devbox-agent` trusts only
the CN `devbox` from the trust anchor `statuslantern-agent-ca`; `arns.env` in
the same folder holds the trust anchor and profile ARNs. The SigNoz rule
`devbox AWS certificate expiring or missing` ([Telemetry](#telemetry)) posts to
Slack 30 days before the certificate expires, or when its metric stops for 2
hours.

To renew it, first copy the CA key to the box from nixos-desktop or nixos-rog,
whose Infisical CLI is signed in; the box's CLI has no login
([agents/reference/devbox.md](../agents/reference/devbox.md#accounts-and-logins)):

```bash
infisical secrets get ROLES_ANYWHERE_CA_KEY_B64 --plain --silent --projectId "$INFISICAL_STATUSLANTERN_PROJECT" \
  --domain https://eu.infisical.com --env prod --path /agent-aws |
  ssh devbox 'umask 077; base64 -d > ~/.aws/rolesanywhere/ca.key'
```

Then run this on the box as omer. It stops at the first failed step, replaces
`leaf.key` and `leaf.pem` only after the new certificate is valid and matches
the new key, and deletes the CA key on every exit:

```bash
(
  set -euo pipefail
  umask 077
  cd ~/.aws/rolesanywhere
  trap 'rm -f ca.key ca.srl leaf.key.new leaf.pem.new' EXIT
  openssl ecparam -name prime256v1 -genkey -noout -out leaf.key.new
  openssl req -new -sha256 -key leaf.key.new -config leaf.cnf |
    openssl x509 -req -sha256 -days 365 -CA ca.pem -CAkey ca.key -CAcreateserial \
      -extfile leaf.cnf -extensions v3_leaf -out leaf.pem.new
  openssl x509 -noout -checkend 0 -in leaf.pem.new
  cmp <(openssl pkey -in leaf.key.new -pubout) <(openssl x509 -in leaf.pem.new -pubkey -noout)
  mv leaf.key.new leaf.key
  mv leaf.pem.new leaf.pem
)
aws sts get-caller-identity --profile statuslantern
```

Then open SigNoz and check that `tlscheck.time_left` for devbox rises within an
hour, because the collector reads the certificate once an hour and reloads it
when the file changes.

## Deploys

The box installs `main` every hour with `system.autoUpgrade`, as the PCs do
([Updater](workstations.md#updater)), and reboots at night when the new `main`
changes the kernel, the initrd or the kernel modules. That install has none of
deploy.sh's rollback, so a `main` that breaks sshd or Tailscale leaves only the
provider's console. [Deploy to a server](deploy.md#deploy-to-a-server) has the
reboot, the failure signal and the root login.

A deploy from nixos-desktop or nixos-rog logs in as root, not as omer, because
omer's sudo asks for a password (`deployLogin` in the machine record). The release
records are in `/root/.local/state/nixos-config-deploy/`.
The long-running agent units of omer are in `oruc.deploy.sessionIgnore` in
`configuration.nix`. deploy.sh's session check leaves them out of a deploy as
omer. A deploy as root, which is every deploy from another host, checks only root's own
services.

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
  journal; a config error exits with
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
`/etc/subgid` come from `machines/devbox/configuration.nix`.

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
  The failure shows in `systemctl --user --failed` and in the journal.
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
  Claude account tools of `pkgs/claude-tools` with their usage timer, and
  `claude-tools-limit-switch.timer` (next bullet).
- `claude-tools-limit-switch.timer` runs `claude-tools limit-switch scan` of
  `pkgs/claude-tools` every minute. A run starts herdr's default session through
  `herdr-default.service` when no server runs, starts the recorded Claude agents
  again after a server restart, and moves each named agent whose session
  transcript ends in a usage limit error to another account. A run fails when
  an agent could not move, when a recorded agent could not start again, or
  when herdr's server did not start. The log names the agent, or the step that
  failed, and the reason:
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
  `configuration.nix` writes Amp's `/etc/ampcode/managed-settings.json`, which
  Amp reads above its user settings, with `amp.remoteThreadCreation.enabled`,
  so ampcode.com can open threads on the box. OpenChamber and OpenCode keep
  their own settings files, which they write themselves; nothing copies them
  elsewhere, so a reinstall starts them from their defaults.
- `stay-green.timer` starts a run every 4 minutes around the clock. A run keeps
  Omer's Teams status Available on weekdays from 09:00 to 18:00 Istanbul time
  with `pkgs/stay-green.nix`, built from the `stay-green` flake input, and does
  nothing outside that schedule. The sign-in is in `~/.local/state/stay-green`. A
  failed run usually means the sign-in expired or was revoked; sign in again
  from a workstation with `stay-green login devbox`. Read a run with
  `journalctl --user -u stay-green.service -n 20`.
- The Status Lantern factory's user units (`machines/devbox/home.nix`):
  `statuslantern-audit.timer` at 06:00 Istanbul, `statuslantern-factory-triage.timer`
  at 08:00 Istanbul, `statuslantern-nightly.timer` and
  `statuslantern-factory-run.path`. The triage unit starts at most one run a
  UTC day, so a catch-up after a late boot (`Persistent=true`) starts none when
  the day's start is taken. Each of the four services writes the failure
  marker below to `~/.local/state/<unit>/failed`, which each new shell prints
  until a run succeeds. SigNoz rules cover only part of these failures:
  `audit-missed-run` fires when no `audit.run` log arrives, `nightly-failed`
  when `nightly.run` reports the outcome `failed` or `held`, and
  `nightly-missed-run` when no `nightly.run` arrives. No rule fires on a triage
  failure, or on a `factory-run` that fails without posting (an unhandled
  error, a timeout or a kill), so the marker shows those. A founder's Stop and
  an error that the run posts to Linear end with exit 0 and clear the marker.
  Status Lantern's `docs/agents/factory.md` holds what each unit starts.
- `infisical-agent.service` (`machines/devbox/home.nix`) runs the
  [Infisical Agent](https://infisical.com/docs/integrations/platforms/infisical-agent)
  as omer, with the config that the sops template `infisical-agent.yaml` in
  `machines/devbox/services.nix` renders, so the project id stays out of this
  repository. It logs in with the machine identity's universal-auth client id
  and secret, keeps the access token in `$XDG_RUNTIME_DIR/infisical-agent/token`,
  and writes the folder `/harness/openrouter-guardrail` as
  `openrouter-guardrail.env` next to it, checking for changes every 5 minutes
  (the agent's default). The config names both files relative to the unit's
  `WorkingDirectory`, which is that folder. The unit counts as started only once
  the env file exists (`ExecStartPost`, at most 60 s), so a unit ordered after
  it finds the file. The folder is mode 0700 and the files 0600
  (`RuntimeDirectoryMode`, `UMask`), and systemd deletes them when the unit
  stops. A change to the config restarts the unit (`X-Restart-Triggers`); a
  rotated client secret in sops needs `systemctl --user restart infisical-agent`.
  A one-off command reads a folder with that token, and must name the project,
  because a machine-identity token ignores `.infisical.json`:
  `INFISICAL_TOKEN=$(<"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/infisical-agent/token") infisical run
  --domain https://eu.infisical.com --projectId <project-id> --env secrets
  --path /harness/<folder> -- <command>`. Read the agent's log with
  `journalctl --user -u infisical-agent -n 20`.
- `openrouter-free-guardrail.timer` runs once a day
  (`home-manager/modules/openrouter-free-guardrail.nix`). A run reads OpenRouter's
  public model list, keeps the models whose prices are all 0 and that support
  structured outputs, and sets them as the allowed models of the
  `threadsift-free-only` guardrail through the management API, creating the
  guardrail when it is missing. A run refuses an empty list, because a guardrail
  with no allowed models allows every model, and it fails before any write when
  the account has no workspace or key it expects once (the workspace `default`
  and the key `threadsift-verify`) or two policies named `threadsift-free-only`.
  The update (a PUT) replaces only `allowed_models`. It sends back every other
  field of the policy's `config` that the API accepts when it writes a
  policy, such as `allowed_providers`, `enforce_zdr` or `ignored_models`, and
  the policy's members and opted-out lists, so a setting made in the
  OpenRouter dashboard survives. It adds `threadsift-verify` to the key
  assignment and removes no key, so a key added by hand stays assigned. The
  create call (a POST) is not retried, because a retry after a server-side
  commit would create a second policy. The unit reads `OPENROUTER_MANAGEMENT_KEY`
  from `%t/infisical-agent/openrouter-guardrail.env`, which the Infisical Agent
  writes. It wants and starts after `infisical-agent.service`; a missing file
  leaves the key unset, and the script then fails with
  `OPENROUTER_MANAGEMENT_KEY is not set`. Each call times out after 30 s and retries for at most 60 s, so a
  run can take 33 calls of at most 90 s each (the 10 pages each of the
  workspace, key and policy lists, the model list, the policy read and the
  write), and the unit stops it after 1 hour. A run that changes nothing logs
  `threadsift-free-only unchanged: <models>`; read a run with
  `journalctl --user -t openrouter-free-guardrail -n 20`, because journald
  can drop the unit fields from the last line of a process that exits at once,
  so `-u` missed the `updated` line of a run on 2026-11-07, and the unit sets
  `SyslogIdentifier=` to its name.
- The failure marker. Every unit built with
  `home-manager/modules/scheduled-unit.nix`, and the four Status Lantern units
  above through `failureMarker` in `machines/devbox/home.nix`, run a
  marker command as `ExecStopPost=`, which systemd runs after every run with
  `$SERVICE_RESULT` set ([systemd.service(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html)).
  The marker is `~/.local/state/<unit>/failed`. Any result except `success`
  writes it, including a non-zero exit, a kill by signal, a `TimeoutStartSec`
  stop, and a run without `openrouter-guardrail.env`. A
  successful run deletes it. Each new shell prints the marker's line until a
  run succeeds. A run that `systemctl --user stop` cuts short counts
  as a failure too (the result is `signal`).

## Factory run user

The Status Lantern factory runs its agents as the user `sl-factory`
(`machines/devbox/configuration.nix`), so an agent that reads alert and audit
text holds none of omer's credentials. The user has its own group, a home with
mode 700, no `extraGroups` and no subordinate uid range, because it runs no
containers. `users.mutableUsers` is off, so the account comes only from this
repository. The user can still install packages with `nix profile install`,
because `nix.settings.allowed-users` is `*`. It is not in `trusted-users`.

- Packages: `devenv`, `git`, `jq`, `openssh`, and Claude Code, Codex and Grok
  from `inputs.llm-agents`, the same attributes omer's profile takes, and the
  reviewer's four tools (Reviewer, below).
- Sudo: `omer` may run any command as `sl-factory` without a password. The rule
  gives no passwordless access as another user, and omer's wheel access still
  asks for his password. `sl-factory` cannot run `sudo` at all
  (`security.sudo.execWheelOnly`). `sudo -u sl-factory -i factory-pane
  <worktree> <account> <command> [args]` runs the command in a devenv
  shell in a factory worktree. `Defaults>sl-factory !use_pty` makes sudo share the
  caller's terminal for that run user only, so herdr, which watches the
  terminal's foreground process, detects an agent started that way; omer's other
  sudo calls keep `use_pty`. A process of `sl-factory` that keeps the terminal
  open after its agent exits could read what omer types next in that pane, so
  `boot.kernel.sysctl."dev.tty.legacy_tiocsti"` is 0 explicitly, which stops it
  pushing keystrokes into omer's shell, and `factory-run` stops the agent's
  scope and closes its workspace when a run ends (Statuslantern
  `docs/agents/factory.md`, Run user). The boot check asserts the sysctl and the
  sudoers line.
- Reviewer: `machines/devbox/factory-agent-files.nix` links the `code-reviewer`
  and `comment-sicko` agents and the `ub-mode` and
  `thermo-nuclear-code-quality-review` skills into `~/.claude` and into each
  account folder in its `accounts` list, and `core.md` and
  `testing-discipline.md` into `~/.claude/shared`, which are the files the
  reviewer reads. `agents`, `skills` and `shared` are whole links to a
  read-only store path, so no run plants an agent or a skill that stays, and
  tmpfiles replaces a real folder put there at the next boot or switch. An
  edit to these files reaches the user at devbox's next upgrade, unlike omer's
  live links (`agents/README.md`). The user's profile holds `codex-ask`,
  `wait-exit`, `sandbox-run` and `dryer`, Codex is logged in, so the second pass
  with gpt-6.1-sol runs, and `/tmp/agents` is mode 1733, owned by omer, with the default ACL
  `other::---`, so `sl-factory` can make its scratch folder there but cannot
  list the folder, and no folder that omer or `sl-factory` makes there is
  readable by the other users whatever their umask. Statuslantern's
  `factory-run` lands a fix only when the run's account folder holds
  `agents/code-reviewer.md` (`docs/agents/factory.md`). The boot check asserts
  the links, the commands, the scratch folder and that `sl-factory` cannot read
  a folder omer makes there.
- Usage: `claude-tools` finds an account only as a folder `~/.claude-<name>`
  that holds a `.claude-profile` file, so `factory-agent-files.nix` links each
  `~/.claude-accounts/<name>` as `~/.claude-<name>` and makes that file.
  `claude-tools-usage-factory.timer` runs `claude-tools usage --quiet` as
  `sl-factory` every 10 minutes. The unit passes the `claude-tools-accounts`
  secret as a systemd credential (`LoadCredential`), and its `ExecStartPre`,
  also running as `sl-factory`, writes `~/.config/claude-tools/accounts.json`
  from it without `remote_hosts`, because `sl-factory` has no ssh key for the
  other devices. Root writes nothing into that home, so a link planted there
  cannot redirect a root write. The cache `~/.cache/claude-tools/usage.json` then holds the
  logins of the accounts the factory's agents use, which `omer`'s own cache
  does not. The timer shares `.credentials.json` with a running agent, and
  `claude-tools` only reads it (`pkgs/claude-tools/src/claude_tools/usage.py`,
  `oauth`): `api_usage` sends the access token to the usage endpoint while it
  is valid for more than 300 s, and otherwise, or on a 401, `probe` runs
  `claude -p --max-turns 1` on haiku with the account's `CLAUDE_CONFIG_DIR`, so
  Claude Code refreshes the token and writes the file itself, as it does for
  the agent's own turn. Statuslantern's `factory-run` reads it with `sudo -u sl-factory
  claude-tools usage --order --cached`.
- Lingering: `linger = true` keeps the user manager of `sl-factory` running
  without a login, because Statuslantern's `agent-start` runs each agent in its
  own user scope, `factory-agent-<agent name>.scope`, and stopping one scope
  leaves the other agents of the run user, such as the nightly agent, running.
  A running user manager also lets an agent start or enable user units outside
  its scope, which keep running across runs and reboots with the rights of
  `sl-factory` and behind the same network fence. Statuslantern's
  `docs/agents/factory.md`, Run user, records that residual. The boot check
  asserts `/var/lib/systemd/linger/sl-factory`.
- Network: `networking.firewall.extraCommands` adds the chain `sl-factory-out`
  for packets of `sl-factory`. It allows the resolvers `127.0.0.53` and
  `127.0.0.54` on port 53 and observability-1's tailnet address
  `100.127.140.73` on tcp 443, where `signoz.statuslantern.com` serves the
  SigNoz API. It rejects everything else sent out of `lo` and `tailscale0`,
  because omer's services on loopback, such as the box browser's DevTools, and
  the tailnet's SSH answer without a password. A process of `sl-factory` that
  needs another loopback port fails, so a new need adds an exception there.
  The fence assumes devbox uses no Tailscale exit node, so internet traffic
  leaves by `ens3`. It covers TCP and UDP on network sockets only, so a Unix
  socket of omer, such as an X server's, needs its own access control. A reload
  never leaves `sl-factory` without the fence. The chain `sl-factory-out` and the
  owner-matched jump from `OUTPUT` stay in place, and `iptables-restore
  --noflush` and `ip6tables-restore --noflush` empty and refill the chain in one
  nf_tables commit, so a restore that fails keeps the old rules. A start adds
  the chain and the jump only when they are missing.
  `networking.firewall.extraStopCommands` is empty, so `systemctl stop firewall`
  keeps the fence as well. The boot check starts 64 loops of `sl-factory` that
  try port 2222, waits until they have written output, reloads the firewall three
  times and checks that the output grew across each reload, that no try got
  through, and after each reload the owner jump, the chain's two `REJECT` rules and
  `-A INPUT -j nixos-fw`. No test covers the first reload over a fence that an
  older configuration made on a live host; the `./deploy.sh devbox switch` after
  a change shows it.
- X displays: Xvnc of the box browser (`:20`) and the Cursor worker's `Xtigervnc`
  (`nixosModules/agent-runtime.nix`) start with `-auth ~/.Xauthority`, so
  `sl-factory` cannot open them over the X socket. The `Xtigervnc` wrapper keeps
  one cookie in `~/.local/state/xtigervnc-cookie` and writes it for `:0` to `:9`,
  because the worker picks the display number itself. `cursor-worker.service`
  sets `XAUTHORITY=%h/.Xauthority`, so its clients read the same file even when a
  desktop session puts another `XAUTHORITY` into the user manager's environment.
- `factory-pane` is a stub that runs `<worktree>/nix/devenv/factory-pane.sh`
  from the statuslantern checkout, so that script changes with the repository.
- The logins, the clone and the SigNoz key of `sl-factory` are state, not
  configuration. Statuslantern's `docs/agents/factory.md`, Run user, lists them.

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
  recreates the containers whose image changed. When a container of the stack
  is stopped or missing, the reload starts the whole stack again, as a start
  does. The images float (`env.public`, `tls-proxy/Dockerfile`), so the reload
  logs each image id it replaces and its successor to
  `journalctl --user -u cliproxy.service`, and tags the replaced image
  `localhost/cliproxy-previous/<container>:latest` until the next replacement.
  To go back to it, stop `cliproxy-update.timer`, which stays stopped until the
  next login or Home Manager activation. Then tag the previous image in
  Podman's store with the name `env.public` gives, such as
  `podman tag localhost/cliproxy-previous/cliproxy:latest docker.io/eceasy/cli-proxy-api:latest`,
  and restart `cliproxy.service`. A start pulls no image that exists locally.
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
  is in `secrets/devbox.yaml`). Turn on Save password at that login, and
  Remmina keeps the password in the session's Secret Service and connects
  without asking from then on. It does so only when the Secret Service has the
  `default` alias, which step 2 of `home-manager/README.md` checks; without
  it, Remmina keeps the password in the profile file, and the next Home
  Manager switch replaces it. A Home Manager step writes the profile with
  `password=.`, the value that tells Remmina to read the Secret Service, so a
  profile the step writes anew still finds a password stored earlier. The
  step also turns on dynamic resolution, so the desktop follows the window
  size. Without it, a quick connect from nixos-desktop on 2026-10-30 kept the
  size Remmina read from its window before the window mapped, 644x480. The
  profile shares the PC's home folder, which appears on devbox under
  `~/thinclient_drives` while the session runs, where devbox's agents can read
  and write it too, and asks for the session's sound (the Audio bullet below).
  The step also sets Remmina's RDP keyboard layout to Turkish Q. Remmina's
  default colour depth ("Automatic") gets H.264 from xrdp.
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
  which it allows by default. The XFCE screensaver is off, because it would
  lock the Cursor worker's session, and xrdp checks the password at every
  login and reconnect.
- **Logs.** xrdp's logs go to the journal, where the NixOS module sends them to
  `/dev/null`, so a failed xrdp unit shows in `systemctl --failed`.
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
only. The same module's memory-pressure kill does run here: systemd-oomd
watches the slices of omer's user manager, and
`memory-pressure-snapshot.service` writes a process snapshot to
`~/.local/state/oom-snapshots/` when pressure rises
([Out of memory](recovery.md#out-of-memory)). `/tmp` stays on the disk, loses
files untouched for 7 days, and keeps `/tmp/tmux-*`, `/tmp/.X11-unix` and `/tmp/.ICE-unix`.

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
`ci/server-boot/secrets.yaml`, under the key the host reads.
`ci/server-boot/modules/sops.nix` points every secret that names its own
`sopsFile` on the host at the test file, so a new key needs nothing else. A
NixOS module that only the test machine loads, such as a stub of an external
service, goes in `ci/server-boot/modules/`.

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

## What no test covers

A deploy rolls back when a system unit fails during the switch or root's
session check fails ([Deploys](#deploys)). After a deploy, run `systemctl
--failed` and `systemctl --user -M omer@ --failed` on the box. These show only
in daily use:

- **The run user's isolation.** The boot check covers the empty subordinate
  uid range, the sysctl, the sudoers line, the firewall rules, one loopback
  connection each way and a probe that `sl-factory` runs through three firewall
  reloads. No check covers the first reload over the fence of an older
  configuration on a live host, the terminal sharing, herdr's detection of an
  agent behind sudo, or the reach of `sl-factory` on the real tailnet.
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
- **The hourly install.** `nixos-upgrade.service` switches with no rollback
  timer, session check or SSH check, so a unit that fails after its switch
  stays failed.
- **A unit that fails only at boot.** Nothing rolls back after the night
  reboot ([Deploy to a server](deploy.md#deploy-to-a-server)).
- **The night reboot.** No test reboots for a kernel change or checks the
  window; the assertion in `nixosModules/auto-upgrade.nix` only ties the
  window to the time zone.
- **deploy.sh's own checks on devbox.** The `deploy-script` VM check runs the
  rollback, the session check's ignore list and the boot entries on a VM that
  deploys to itself ([Test deploy.sh in a VM](deploy.md#test-deploysh-in-a-vm)).
  No test deploys to devbox over SSH as root, and nothing checks that omer's
  sudo asks for a password.

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
