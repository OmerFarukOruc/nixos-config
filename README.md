# nixos-config

NixOS hosts, deployed from fedora-desktop over Tailscale.

| Host | Machine | Role |
| --- | --- | --- |
| nixos-latitude | Dell Latitude 3550 | home lab box with one login session, niri with the Noctalia shell |
| nixos-rog | ASUS ROG Zephyrus G16 GA605WI | daily laptop, with Plasma, niri with Noctalia and niri with DMS as login sessions |
| nixos-desktop | the desktop PC that runs fedora-desktop today | planned; inventory metadata only |

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
DankMaterialShell. Its [README](kernel-cache/README.md) explains how the hosts
follow it.

## Check and deploy a change

Run deploy commands from fedora-desktop. The script copies source-controlled files
to a fresh release under `~/.local/state/nixos-config-deploy/releases/` and builds
the system from that immutable candidate on the target. After a successful deploy, it
atomically updates `~/.local/state/nixos-config-deploy/current`. Failed candidates
remain available for inspection, and earlier releases are never modified.
fedora-desktop has no Nix installed. The SSH alias `nixos-latitude` in
`~/.ssh/config` selects the target and its SSH key.

Check evaluation and build the system on the target without activating it:

```sh
ssh nixos-latitude 'cd "$(readlink -f ~/.local/state/nixos-config-deploy/current)" && nix eval --raw --no-write-lock-file .#nixosConfigurations.nixos-latitude.config.system.build.toplevel.drvPath'
ssh nixos-latitude 'cd "$(readlink -f ~/.local/state/nixos-config-deploy/current)" && nix flake check --no-build --no-write-lock-file'
ssh nixos-latitude 'cd "$(readlink -f ~/.local/state/nixos-config-deploy/current)" && nix build --no-link --no-write-lock-file .#nixosConfigurations.nixos-latitude.config.system.build.toplevel'
```

These checks use the source selected by the `current` symlink. They prove
evaluation or build success only. They do not activate the generation or prove
that the hardware and services work after activation.

CI runs the formatter check, `nix flake check --no-build` and the evaluation of every
host on every pull request and on every push to `main`. To format locally, run
`ssh nixos-rog 'cd <copy of the repo> && nix fmt'`, because fedora-desktop has no
Nix, then copy the changed files back.

Every deploy command below can change boot or running system state. Run one only
after activation is separately authorized. `switch` is the default. It activates
the generation now and makes it the boot default:

```sh
./deploy.sh nixos-latitude
```

Use `test` to activate until reboot without changing the boot default, or `boot`
to set the boot default without activating the running system:

```sh
./deploy.sh nixos-latitude test
./deploy.sh nixos-latitude boot
```

`switch` and `test` confirm or roll back. The script builds the candidate on the
target first and changes nothing if the build fails. It then arms a 420 second
timer (`deploy-rollback.timer`) that restores the previous system, and activates
the candidate with `switch-to-configuration test` in a system service, so an SSH
drop cannot interrupt it. The script then opens fresh SSH logins and checks that
`sshd` and `tailscaled` are active. A host that deploys itself (the host name
given is its own) runs every step locally and checks the two units without an
SSH login. When the deploy user is logged in, the script also records that
user's running services before activation, except those a timer, socket or path
started, apps a launcher started (`app-*`), `systemd-run` jobs (`run-*`) and
transient D-Bus services (`dbus-*`). The script stops before it arms the timer
when it cannot list them. Twenty seconds after the SSH
check, if one of them has failed or waits to restart, or the script cannot query
them, it restores the previous system at once and exits 75. This catches a switch that breaks the
desktop shell or compositor while SSH still answers. Only after that does it stop the timer, and
for `switch` it makes the confirmed build the system profile and boot default
without building or activating it again. If activation fails, the
script restores the previous system at once. A unit that fails during activation
(`switch-to-configuration` exit 4) counts as a failed activation. When the SSH
connection drops during activation, the script reconnects and waits up to 180
seconds for the exit status that the activation unit records in
`/run/deploy-activate.status`, and restores the previous system when it is not 0.
When the restore fails, the script prints that the target may still run the
candidate and leaves the timer armed, which repeats the restore at its deadline.
The boot default is unchanged then, so a reboot also restores the previous system. If the target
stops answering, the timer restores the previous system after 420 seconds,
without any command from this machine. A candidate that is never confirmed never
becomes the boot default.
After the build, the script prints dix's comparison of the running and the new
system; a failed comparison does not stop the deploy.
Before it changes the boot default, the script checks that `/boot` is mounted
(exit 79 otherwise) and that the ESP has room for
every kernel and initrd of the new generation and its specialisations plus 1 GiB,
and exits 74 without touching the ESP when it does not. If installing the boot
entries fails, it sets the system profile and boot entries back to the previous
generation and exits 73.
`boot` builds the same way, then makes the build the system profile and boot
default. It activates nothing and has no timer. A pending `deploy-rollback.timer` from
an earlier run makes the next deploy stop before it changes anything.

The script refuses a dirty Git tree. After reviewing every local change, use the
single dirty-deploy escape hatch when that state is intentional:

```sh
./deploy.sh --allow-dirty nixos-latitude test
```

The dirty deploy includes modified tracked files and non-ignored untracked files.
Ignored files are never copied.

Each release has a record beside it,
`~/.local/state/nixos-config-deploy/releases/<release>.source`. The record names
the machine and checkout it came from, the branch, the commit, whether the tree
was dirty, the action, and `CLAUDE_CONFIG_DIR` when an agent deployed it.
Promotion adds the system it built. To see who deployed what a host runs, read
the record whose `system=` line matches `readlink -f /run/current-system`.

Only one deploy runs on a host at a time. A second deploy exits 77 and names the
deploy that holds the lock. The lock goes when that deploy exits or loses its
connection. Keepalives on both ends close a dead connection within about 45
seconds. When a deploy finds its own lock dropped before activation, it takes the
lock again and repeats the check below, reads the running system again for the
rollback, and exits 77 if another deploy holds it by then or 70 if it left a
rollback timer. During activation the pending rollback timer keeps other deploys out.

Before it uploads anything, the script checks the release that runs on the host
and the release that is its boot default. When one of them came from another
checkout and holds a version of a file that is neither in the candidate nor
anywhere in this checkout's history, the script exits 78. It prints that
release's record and the files the deploy would drop. A squash-merged branch
passes, because each version it deployed is in `main`'s history. Merge the work
into this checkout, or rerun with `--replace` after its owner agrees:

```sh
./deploy.sh --replace nixos-rog test
```

When the target check, the rebuild or the activation fails, the failed release
stays on the target and the local `flake.lock` stays unchanged. The script copies
the target's `flake.lock` back into this repository only after the whole deploy
succeeds. A build that succeeds and then rolls back changes nothing locally.
Commit the lock change before the next clean deployment.

To update the CachyOS kernel, move its input to the revision that the
[kernel-cache](kernel-cache/README.md) workflow last built.
The script first checks that the kernel and the NVIDIA open module of that
revision are in the `omerfarukoruc` Cachix cache, and leaves `flake.lock`
unchanged when they are not, so a host never compiles the kernel itself:

```sh
scripts/update-kernel.sh
```

When the script reports missing paths because the GitHub runner is slow or timed
out, build the revision on fedora-desktop instead. This takes the Cachix push
token from Infisical, builds the variants in a `nixos/nix` container, pushes
them, and starts the kernel-cache workflow to record them; run `update-kernel.sh`
again once that workflow finishes:

```sh
cd ~/Desktop/workspace && CACHIX_AUTH_TOKEN=$(infisical secrets get CACHIX_AUTH_TOKEN_FEDORA_DESKTOP --plain --silent --env secrets --path /nixos-config) \
  ~/Desktop/workspace/nixos-config/kernel-cache/scripts/build-local.sh --rev <nix-cachyos-kernel sha> --record zen4 x86_64-v3
```

`nix flake update` moves the kernel input too. Use `nix flake update <input>`
for the other inputs.

`scripts/update-release-tags.sh` moves inputs pinned to a GitHub release tag
(`github:owner/repo/v1.2.3` in `flake.nix`) to that repository's newest release
and locks them: all of them, only the inputs named, or with `--except` all but
those.

`scripts/update-app.sh NAME` moves `pkgs/NAME.nix` to the vendor's newest
release, and prints it, or prints nothing when it is current. Claude Desktop and
ChatGPT name an APT index in `passthru.aptIndex`; OpenChamber names its
electron-builder feed (`latest-linux.yml`) in `passthru.releaseFeed`. A feed
release moves its app only once it is 3 days old, by the feed's `releaseDate`.
The auto-updater builds each moved app on its own first. A version that does not
build stays out of the update and sends one notification, so the other updates
go ahead. An app whose update check fails (an unreadable feed or index, or a
feed file that is not the one the package downloads) stays where it is and
sends one notification per distinct error, until a check succeeds.

The deploy checks only what it can see: the build, activation, SSH, Tailscale
and the running user services. A program that starts but misbehaves stays
installed.

Release cleanup is explicit. The command below keeps the five newest candidates,
always protects the release selected by `current` and the releases whose records
match the running system or the boot default, prints every older release it will
delete, and then removes those disposable source copies with their records:

```sh
./deploy.sh nixos-latitude prune
```

If a rebuild fails, inspect its complete output, fix the source on
fedora-desktop, and rerun the chosen deploy command. The failure message names
the candidate release retained for read-only investigation. The `current`
symlink continues to identify the last successful release. Do not run a
different target-side rebuild and then forget to apply the same fix here.

For example, re-run the evaluation and build commands above, then retry the same
non-persistent test action after the fix is authorized:

```sh
./deploy.sh nixos-latitude test
```

## Roll back or recover nixos-latitude

Each host keeps the newest 5 system generations, one from each of the last 7
days, the running one, and the booted one. The boot menu lists only the newest
5. angrr removes the others before the weekly `nix-gc`, which then
deletes the unreachable store paths.

To switch a running host back to its previous retained generation:

```sh
ssh -t nixos-latitude 'sudo nixos-rebuild switch --rollback'
```

If the host does not boot, use the local console. Select an older NixOS generation
in the systemd-boot menu. After it starts, make that selected generation the next
boot default:

```sh
sudo /run/current-system/bin/switch-to-configuration boot
```

To go back to a kept generation that the boot menu does not list, pick its
number from the list and make it the current and default generation. On
nixos-rog, first stop the updater with
`sudo systemctl mask --runtime --now oruc-auto-update.timer`, or its next
update deploys `main` again.

```sh
sudo nix-env -p /nix/var/nix/profiles/system --list-generations
sudo nix-env -p /nix/var/nix/profiles/system --switch-generation <number>
sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

The normal generation uses the selected CachyOS kernel. For stock-kernel recovery,
reboot and select the `recovery` specialisation for the required generation in
the systemd-boot menu. A runtime switch cannot load a different kernel. Confirm
the running kernel after reboot:

```sh
uname -r
```

If the bootloader itself needs repair, boot the NixOS installer, mount the existing
filesystems, and reinstall the boot entries from the retained system profile:

```sh
sudo -i
mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount -o umask=077 /dev/disk/by-label/BOOT /mnt/boot
nixos-enter --root /mnt
NIXOS_INSTALL_BOOTLOADER=1 /nix/var/nix/profiles/system/bin/switch-to-configuration boot
exit
reboot
```

The installed Latitude disk has one ext4 root partition and no disk-backed swap.
It keeps its existing zram swap until a non-destructive swap-file or offline
repartition plan is chosen. Zswap stays deferred with that storage decision because
NixOS requires a physical swap device and rejects using zswap with zram.

## First install of nixos-latitude

Run on the laptop from the NixOS minimal ISO. fedora-desktop serves this repo
over the LAN at <fedora-desktop-ip>:8090 during the install.

1. In BIOS (F2 at the Dell logo): turn off Secure Boot. Set boot mode to UEFI.
2. Boot the USB stick (F12 at the Dell logo picks the boot device).
3. Connect Wi-Fi:

   ```
   sudo -i
   wpa_passphrase 'SSID' 'PASSWORD' > /etc/wpa_supplicant.conf
   systemctl restart wpa_supplicant
   ping -c 2 <fedora-desktop-ip>
   ```

4. Partition the internal disk. Check the device name first with `lsblk`.

   ```
   DISK=/dev/nvme0n1
   parted "$DISK" -- mklabel gpt
   parted "$DISK" -- mkpart ESP fat32 1MiB 4097MiB
   parted "$DISK" -- set 1 esp on
   parted "$DISK" -- mkpart root ext4 4097MiB 100%
   mkfs.fat -F 32 -n BOOT "${DISK}p1"
   mkfs.ext4 -L nixos "${DISK}p2"
   mount /dev/disk/by-label/nixos /mnt
   mkdir -p /mnt/boot
   mount -o umask=077 /dev/disk/by-label/BOOT /mnt/boot
   ```

   If the disk is SATA, its name is `/dev/sda`. Partitions are then `sda1` and `sda2`.

5. Fetch this repo, generate the hardware file under the current `machines/`
   layout, evaluate it, and install:

   ```
   mkdir -p /mnt/etc/nixos
   curl http://<fedora-desktop-ip>:8090/nixos-config.tar.gz | tar xz -C /mnt/etc/nixos --strip-components=1
   nixos-generate-config --root /mnt --show-hardware-config > /mnt/etc/nixos/machines/nixos-latitude/hardware-configuration.nix
   nix flake check --no-build --no-write-lock-file /mnt/etc/nixos
   nix build --no-link --no-write-lock-file /mnt/etc/nixos#nixosConfigurations.nixos-latitude.config.system.build.toplevel
   nixos-install --flake /mnt/etc/nixos#nixos-latitude
   ```

   `nixos-install` asks for the root password at the end.

6. Set the user password, reboot, remove the USB stick:

   ```
   nixos-enter --root /mnt -c 'passwd oruc'
   reboot
   ```

7. After first boot, log in at the console as oruc:

   ```
   nmcli device wifi connect 'SSID' password 'PASSWORD'
   sudo tailscale up --ssh=false
   ```

   Open the printed URL on any device and approve the machine.
   From then on fedora-desktop reaches it as `nixos-latitude` over Tailscale.

## nixos-rog

nixos-rog shares its ESP with Windows Boot Manager. Limine installs to
`\EFI\limine` with its own firmware boot entry. The install step also copies
the Limine binary to `\EFI\BOOT\BOOTX64.EFI`, so the same menu boots after the
firmware forgets its entries, for example after a BIOS update
(`nixosModules/bootloader.nix`). The Limine menu lists Windows, the NixOS
generations, and a `recovery` specialisation for each generation. The
recovery entry boots `linuxPackages_latest`, because the stock kernel lacks
the `asus-armoury` driver this laptop needs. It runs on the Radeon iGPU without
the NVIDIA driver, so a driver or kernel update never compiles the NVIDIA module
on the laptop for the recovery kernel.

To go back to an older generation, pick it in the Limine boot menu.

Limine always makes the newest generation of the system profile the default,
whatever generation is running. To keep a generation picked in the Limine menu
as the default, boot it, then drop the newer generations and reinstall the boot
entries:

```sh
sudo nix-env -p /nix/var/nix/profiles/system --list-generations
sudo nix-env -p /nix/var/nix/profiles/system --switch-generation <good>
sudo nix-env -p /nix/var/nix/profiles/system --delete-generations <newer...>
sudo /run/current-system/bin/switch-to-configuration boot
```

The firmware GPU mode must be Hybrid mode (see `CONTEXT.md`). In Integrated mode
the NVIDIA driver has no device.

nixos-rog updates itself. Every hour on AC power, `oruc-auto-update.service`
runs `scripts/auto-update.sh` in its own clone of this repository. It updates
every input except the kernel, nixpkgs, DMS and llm-agents. The kernel and
llm-agents move only when a cache holds their builds, and nixpkgs and DMS wait
for the cache for up to a day. The kernel moves through `update-kernel.sh`,
and the other three as described below. The run also moves the release-tagged inputs
with `update-release-tags.sh` and each app with `update-app.sh`, checks that
every other host still evaluates, deploys the result to nixos-rog with
`./deploy.sh nixos-rog switch`, and squash-merges it to `main` through the
`auto-update` branch, with dix's comparison of the old and new system in the
PR body. A desktop notification reports each update or failure. A message
that would repeat every hour (a failed app check, a build that fails) is sent
once, and only after a notification was shown; when no desktop session is
running, the run sends it again next time.
When GitHub cannot be reached, the run exits quietly and tries again next time.
A clone or fetch that fails while GitHub answers (an expired or revoked token,
lost access to the repository) is a failure and sends a critical notification.
The service stops a run after 2 hours (`TimeoutStartSec`) and the script sends
a notification. A stop during `deploy.sh` leaves its rollback timer to restore
the previous system after 5 minutes. The stopped run records no failed
candidate, so the next run tries it again, and exits 70 if the rollback has not
fired yet.
A run where no input or app moved logs "Everything is current." and deploys
nothing, so a change merged to `main` reaches nixos-rog with the next update
or with a manual `./deploy.sh nixos-rog switch`.
A candidate that failed is not tried again until `main` or an upstream moves,
unless deploy.sh stopped for a pending rollback timer (exit 70), a rollback
timer it could not arm (exit 71), a full ESP (exit 74), or an unmounted `/boot`
(exit 79). A candidate where another host
no longer evaluates fails with exit 76. When another deploy holds the lock (exit 77) or nixos-rog runs a
release whose files `main` lacks (exit 78), the run stops without a failure and
the next run tries again. The first run that exit 78 holds back sends an
"Update waiting" notification, and so does a second run in a row that exit 77
holds back.

When the new llm-agents revision has a coding agent that cache.numtide.com
does not hold yet, or the run cannot tell, llm-agents stays where it is, so
the laptop does not compile an agent at full load; the next run tries again.

Noctalia comes from nixpkgs, so the NixOS cache holds it. DankMaterialShell
follows this flake's nixpkgs, so each new nixpkgs or DMS release needs a new
DMS build. Every hour the
[shells-cache](.github/workflows/shells-cache.yml) workflow builds it
for the head of nixos-unstable and the newest DMS release and pushes it to the
`omerfarukoruc` Cachix cache. The run moves nixpkgs and the DMS tag only once
that cache holds the build, so nixpkgs updates can lag nixos-unstable by an
hour or two, and the laptop downloads DMS instead of compiling it. After a day
without that build, nixpkgs moves anyway, the laptop compiles DMS, and a
notification says so once. GitHub emails a
failed scheduled run of that workflow.

If `main` moves during the build, the host keeps the update and the next run
merges it on top of the new `main`. A switch leaves the desktop shell, the
keyring and other user services on their old version; `home-manager/README.md`
lists them.

`oruc-auto-update.service` reads a fine-grained GitHub token,
`github-update-token`, limited to this repository. The script passes it to git,
gh and Nix in its environment, so any process of `oruc` can read it while a run
lasts. Its timer adds up to 10 minutes of random delay. On battery the service
skips the run. To run it now and read its log:

```sh
ssh nixos-rog 'sudo systemctl start oruc-auto-update; journalctl -u oruc-auto-update -n 50'
```

`secrets/nixos-rog.yaml` holds the NextDNS profile ID (`nextdns-profile`) and the
updater's GitHub token (`github-update-token`). It is encrypted with sops for
fedora-desktop's `~/.ssh/id_ed25519` and for the age key derived from the
laptop's SSH host key (recipients in `.sops.yaml`). Edit it on fedora-desktop
with a `sops` binary from Nix:

```sh
SOPS_AGE_SSH_PRIVATE_KEY_FILE=~/.ssh/id_ed25519 sops secrets/nixos-rog.yaml
```

DNS goes only to NextDNS over TLS. The public names under `risoluto.dev`
(`openchamber.risoluto.dev`, `cliproxy.risoluto.dev`) point at Tailscale
addresses, and the profile's DNS-rebinding protection answers those with
`0.0.0.0`. So the profile's Allowlist in the NextDNS dashboard holds
`risoluto.dev`, which also turns off NextDNS filtering for that one domain.
Without the entry, OpenChamber and cliproxy fail to connect as if the server
were down, and the `risoluto-dev-allowlisted` check in
`scripts/verify-nixos-rog.sh` fails.

When a Wi-Fi sign-in page does not load, switch to the network's own plain DNS
until you are logged in, then back:

```sh
sudo captive-dns on
sudo captive-dns off
```

A reboot also switches back.

The Claude Code and Codex setup comes from the dotfiles checkout at
`~/Desktop/workspace/dotfiles`. Every hour `desktop-sync-config.timer` runs its
`desktop/bin/desktop-sync.sh --config`, which links the rules, skills, hooks and
agents and syncs Claude Code's `settings.json` both ways; Home Manager keeps the
shell and tools. The unit does nothing until that checkout exists.

After a deploy, check the running laptop from fedora-desktop. The script writes
a JSON report under `~/.local/state/nixos-config-verify/` and exits 1 when a
check fails; `--suspend` adds three s2idle cycles:

```sh
scripts/verify-nixos-rog.sh
```
