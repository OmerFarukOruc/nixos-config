# Roll back or recover a host

- [Roll back a running host](#roll-back-a-running-host)
- [A host that does not boot](#a-host-that-does-not-boot)
- [A generation the boot menu does not list](#a-generation-the-boot-menu-does-not-list)
- [Keep a generation on a Limine host](#keep-a-generation-on-a-limine-host)
- [Boot the recovery entry](#boot-the-recovery-entry)
- [Repair the bootloader](#repair-the-bootloader)
- [Swap on nixos-latitude](#swap-on-nixos-latitude)
- [Out of memory](#out-of-memory)
- [nixos-rog](#nixos-rog)
- [nixos-desktop](#nixos-desktop)
- [devbox](#devbox)

Each host keeps the newest 5 system generations, one from each of the last 7
days, the running one, and the booted one. `services.angrr` in
`nixosModules/common.nix` sets this. The boot menu lists only the newest 5,
and the other kept generations stay in the profile without a menu entry.
angrr deletes the generations it does not keep before the daily `nix-gc`. `nix-gc`
then deletes the unreachable store paths. angrr sees only generations with a
root in `/nix/var/nix/gcroots/auto`. The generation `nixos-install` made has
none, so it stays until someone deletes it by hand
([install-nixos-latitude.md](install-nixos-latitude.md), step 9).

nixos-latitude boots with systemd-boot, and nixos-rog, nixos-desktop and
devbox boot with Limine (`bootloader` in `machines/inventory.nix`).
systemd-boot boots the generation that `switch-to-configuration boot` made the
default last. Limine always boots the newest generation of the system profile,
whatever generation runs, so a generation stays only after
[Keep a generation on a Limine host](#keep-a-generation-on-a-limine-host).

Every host installs `main` every hour on top of a generation you restored
([Updater](workstations.md#updater)), and that install makes a new newest
generation. So every rollback recipe below pauses `nixos-upgrade.timer` before
it changes the system profile, and resumes it once `main` holds a fix. The pause lasts until the next reboot, and
`Persistent=true` runs a missed hour soon after boot, so pause it again after
each reboot. [Updater](workstations.md#updater) has the pause, the wait for a
running install, and the resume.

## Roll back a running host

1. Pause `nixos-upgrade.timer` on the host and wait for a running install to
   end ([Updater](workstations.md#updater)).
2. Switch the host back to its previous retained generation, here
   nixos-latitude:

   ```sh
   ssh -t nixos-latitude 'sudo nixos-rebuild switch --rollback'
   ```

   On nixos-latitude, systemd-boot then boots that generation by default, as
   long as the menu lists it. On a Limine host the rollback lasts only until
   the next reboot; to keep it, follow
   [Keep a generation on a Limine host](#keep-a-generation-on-a-limine-host).
3. Resume the timer once `main` holds a fix.

## A host that does not boot

1. Use the local console; devbox has only the provider's
   ([devbox](#devbox)).
2. In the boot menu, select an older NixOS generation. In systemd-boot on
   nixos-latitude, select its entry. In Limine, open its `Generation <number>`
   entry and pick `Default`.
3. As soon as it starts, pause `nixos-upgrade.timer`
   ([Updater](workstations.md#updater)). The missed hourly run starts soon after
   boot and would install the broken `main` again.
4. Make the selected generation the next boot default. On nixos-latitude, run:

   ```sh
   sudo /run/current-system/bin/switch-to-configuration boot
   ```

   On a Limine host, follow
   [Keep a generation on a Limine host](#keep-a-generation-on-a-limine-host)
   from step 3.
5. Resume the timer once `main` holds a fix.

After a kernel panic, a watchdog reset or an unexplained stop on
nixos-latitude, read the files in
`/var/lib/systemd/pstore` when the platform kept them, then run
`journalctl -b -1`. See [nixos-latitude.md](nixos-latitude.md#an-unexplained-stop).

## A generation the boot menu does not list

To go back to a kept generation that the boot menu does not list, do these
steps:

1. Pause `nixos-upgrade.timer` first and wait for a running install to end
   ([Updater](workstations.md#updater)).

2. Run these commands. The first one lists the generations. The second one
   makes the generation you picked the current one, and the third one activates
   it. Use the number of the generation you picked.

   ```sh
   sudo nix-env -p /nix/var/nix/profiles/system --list-generations
   sudo nix-env -p /nix/var/nix/profiles/system --switch-generation <number>
   sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
   ```

   The host now runs the picked generation. On a Limine host, a reboot boots
   the newest generation again. To keep the picked generation there, follow
   [Keep a generation on a Limine host](#keep-a-generation-on-a-limine-host)
   from step 3.

3. Resume the timer once `main` holds a fix.

## Keep a generation on a Limine host

Limine makes the newest generation of the system profile the default, so on
nixos-rog, nixos-desktop and devbox a generation stays the default only after
the newer ones are gone:

1. Pause `nixos-upgrade.timer` and wait for a running install to end
   ([Updater](workstations.md#updater)). Otherwise the next install of `main`
   makes a new newest generation, and Limine boots that one.
2. Boot that generation from the Limine menu (its `Generation <number>` entry,
   then `Default`), and pause the timer again after the reboot, or activate it
   with `switch-generation` and `switch-to-configuration switch` as
   [A generation the boot menu does not list](#a-generation-the-boot-menu-does-not-list)
   describes.
3. Drop the newer generations and reinstall the boot entries. The running
   system is the generation from step 2, so this command writes its boot
   entries:

   ```sh
   sudo nix-env -p /nix/var/nix/profiles/system --list-generations
   sudo nix-env -p /nix/var/nix/profiles/system --switch-generation <good>
   sudo nix-env -p /nix/var/nix/profiles/system --delete-generations <newer...>
   sudo /run/current-system/bin/switch-to-configuration boot
   ```

4. Resume the timer once `main` holds a fix.

## Boot the recovery entry

The normal generation uses the selected CachyOS kernel and the themed greeter.
The `recovery` specialisation of each generation boots the kernel set in
`oruc.recovery.kernelPackages` (the stock kernel by default) with the stock
greeter (`nixosModules/recovery.nix`). It clears
`services.displayManager.sddm.theme`, which `nixosModules/login.nix` sets, in
case the theme renders a blank screen. nixos-rog sets it to
`linuxPackages_latest`; see [nixos-rog](#nixos-rog). A runtime switch cannot
load a different kernel, so recovery needs a reboot:

1. Reboot.
2. In the boot menu of nixos-latitude, select the `recovery` specialisation
   for the generation that you need. On a Limine host, open the generation in
   the Limine menu and pick `recovery`.
3. Check the running kernel:

   ```sh
   uname -r
   ```

4. To stay on the recovery entry past the next hourly run, pause
   `nixos-upgrade.timer` ([Updater](workstations.md#updater)), because that run
   switches the host to `main`.

## Repair the bootloader

When the bootloader of nixos-latitude needs repair, do these steps:

1. Boot the NixOS installer.
2. Mount the existing filesystems and reinstall the boot entries from the
   retained system profile:

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

nixos-rog and nixos-desktop use different mounts. They are in
[nixos-rog](#nixos-rog) and [nixos-desktop](#nixos-desktop).

## Swap on nixos-latitude

The installed Latitude disk has one ext4 root partition and no disk-backed
swap. It keeps its existing zram swap until a non-destructive swap-file or
offline repartition plan is chosen.

Zswap waits for the same storage decision, because NixOS needs a physical swap
device and rejects zswap with zram.

## Out of memory

`nixosModules/memory.nix` sets the limits below. On 2026-10-24 a Ghostty tab
with about 6400 small python3 processes filled RAM and swap twice.
systemd-oomd did not act on memory pressure, and the kernel OOM killer picked
the biggest single process, Ghostty's main process, which closed every tab.
Since then, with swap and memory both above 90%, systemd-oomd kills the leaf
cgroup with the most swap under the user manager's `app.slice`
(`ManagedOOMSwap=kill`), such as that one tab, Brave or a `heavy` build scope.

On 2026-10-31 that kill picked the Ghostty tab that ran the herdr server, which
held 5.8 GiB of swap, and every agent in herdr died with it. The herdr server
now runs as `herdr-default.service` (`home-manager/modules/herdr.nix`) in
`session.slice`, outside `app.slice`, so the swap kill never picks it. oomd
ignores `ManagedOOMPreference=avoid` for swap on a cgroup a user owns
(systemd.resource-control(5)), so moving the server out of the watched slice is
the only protection. For memory pressure, oomd watches each slice of the user
manager and honors herdr's `avoid` there, because the user owns both cgroups.
The root-owned `user.slice` has no pressure kill for that reason, so login and
SSH session scopes outside the user manager have no oomd kill.

Each Ghostty tab is a transient scope with `TasksMax=4096`, `MemoryMax=20G`
and `MemorySwapMax=6G`. On 2026-10-24 the busiest normal tab peaked at 2494
tasks, 16.2 GiB of RAM and 1.7 GiB of swap, and the runaway tab at 18.9 GiB of
RAM and 23.8 GiB of swap, so `MemoryMax` alone would have missed it. The values
sit above the normal peaks; they are not measured limits. That busiest tab ran
herdr and its agents, so `herdr-default.service` takes the same limits on the
workstations; above 20G the kernel kills its largest process.

A herdr server started from a terminal, before the service ran, still lives in
that tab's scope. The service skips its start while any herdr server runs. To
move a running server into the service, stop it from a terminal outside herdr,
which ends its agents: `herdr server stop && systemctl --user start
herdr-default.service`.

`memory-pressure-snapshot.service` writes every process with its parent and
command line, and each user cgroup's memory, to
`~/.local/state/oom-snapshots/` when memory pressure rises, at most once a
minute. The last snapshot before an OOM kill shows what held the memory. Its
trigger (300 ms of stall in a 2 s window) is a guess. A process line is at
most about 230 bytes, so a snapshot of 6000 processes is about 1.4 MB, and the
100 kept files take at most about 140 MB and cover the last 100 minutes under
steady pressure. The service's own 128M memory cap is a guess from a synthetic
snapshot of 6888 processes that peaked at 24 MiB RSS.

## nixos-rog

nixos-rog shares its ESP with Windows Boot Manager. Limine installs to
`\EFI\limine` with its own firmware boot entry. The install step also copies
the Limine binary to `\EFI\BOOT\BOOTX64.EFI`. So the same menu boots after the
firmware forgets its entries, for example after a BIOS update
(`nixosModules/bootloader.nix`).

The Limine menu lists Windows, the NixOS generations, and a `recovery`
specialisation for each generation. The recovery entry boots
`linuxPackages_latest`, because the stock kernel lacks the `asus-armoury`
driver this laptop needs. The recovery entry runs on the Radeon iGPU without
the NVIDIA driver. So a driver or kernel update never compiles the NVIDIA
module on the laptop for the recovery kernel.

To go back to an older generation, follow
[A host that does not boot](#a-host-that-does-not-boot) or
[Keep a generation on a Limine host](#keep-a-generation-on-a-limine-host).
Pick `recovery` in a generation's Limine entry for the recovery kernel.

When the nixos-rog bootloader needs repair, boot the NixOS installer and mount
the filesystems before the `nixos-enter` lines in
[Repair the bootloader](#repair-the-bootloader). The installer has no checkout
of this repository. Read the btrfs UUID and the ESP UUID from
`machines/nixos-rog/hardware-configuration.nix` on another machine, or run
`lsblk -f` in the installer and take the btrfs partition that holds `@nixos`
and the vfat ESP:

```sh
mount -o subvol=@nixos /dev/disk/by-uuid/<btrfs uuid> /mnt
mkdir -p /mnt/nix /mnt/boot
mount -o subvol=@nixos-nix /dev/disk/by-uuid/<btrfs uuid> /mnt/nix
mount -o umask=077 /dev/disk/by-uuid/<ESP uuid> /mnt/boot
```

Then run the `nixos-enter`, `NIXOS_INSTALL_BOOTLOADER=1`, `exit` and `reboot`
lines. The Limine entries then come back after a BIOS update that cleared the
firmware boot entries.

The install ends with `oruc-theme-root --limine`, which rewrites only the ten
colour lines of `limine.conf` to the scheme stored in
`/var/lib/oruc/theme/scheme`. When it fails, it prints why and leaves the
record's colours; the install still succeeds.

The firmware GPU mode must be Hybrid mode (see `CONTEXT.md`). In Integrated
mode the NVIDIA driver has no device.

## nixos-desktop

nixos-desktop uses Limine on its own ESP on the WD disk; Windows keeps the ESP
on the Samsung disk. Its Limine menu lists the NixOS generations, each with
its `recovery` specialisation. Roll back and keep a generation with
[Roll back a running host](#roll-back-a-running-host),
[A host that does not boot](#a-host-that-does-not-boot) and
[Keep a generation on a Limine host](#keep-a-generation-on-a-limine-host).
When its bootloader needs repair, boot the NixOS
installer, mount by partition name, then run the `nixos-enter`,
`NIXOS_INSTALL_BOOTLOADER=1`, `exit` and `reboot` lines of
[Repair the bootloader](#repair-the-bootloader):

```sh
mount -o subvol=@nixos /dev/disk/by-partlabel/nixos /mnt
mkdir -p /mnt/nix /mnt/boot
mount -o subvol=@nixos-nix /dev/disk/by-partlabel/nixos /mnt/nix
mount -o umask=077 /dev/disk/by-partlabel/nixos-esp /mnt/boot
```

## devbox

devbox has no keyboard or screen we reach, so its only console is the one in
netcup's Server Control Panel (SCP), a web page. No one has used it on this box
yet, so every step below that names an SCP button is unverified. The agent that
first runs it corrects this section with what it saw, in the same session.

**When to use it.** Only when devbox stays unreachable after a reboot or a
switch: `tailscale status | grep devbox` shows `offline` for more than about 6
minutes, and `timeout 10 ssh root@devbox true` fails. A shorter outage is a
reboot in progress ([Deploy to a server](deploy.md#deploy-to-a-server)).
Write down what you checked and when (`date -u +%FT%TZ`) before step 1.

**Ask first, every time.** The SCP needs Omer's netcup login, and a reset there
cuts every process on the box, so neither an earlier yes nor this section
authorizes it. Ask with one question that names what is down, since when, and
the steps you will take, for example: "devbox is offline since 02:14 UTC after
the night reboot. May I open netcup's console in the box browser on nixos-desktop,
look at the screen, and if it hangs at boot, reset the box and pick the
previous generation in the Limine menu?" Never use SCP's reinstall, rescue
system, image, snapshot or disk options; those are Omer's to run.

**Steps.** Drive nixos-desktop's box browser with the agent-browser skill
(`box-browser`). When it lacks the netcup login, ask Omer to sign in there with
`box-view local` ([box-browser.md](box-browser.md)).
Save a screenshot of the console after each step under
`/tmp/agents/<task>-<session8>/console/`, and report each step and its
screenshot in the final message, so Omer can follow what was done.

1. Open `https://www.servercontrolpanel.de/` (unverified address). When it shows
   a login, stop and ask Omer to sign in in that tab; never type his password or
   his second factor.
2. Pick the server whose name or IP matches devbox and open its console
   (noVNC). Read the screen before you press anything:
   - a login prompt on tty1 means the system runs, so the fault is the network,
     sshd or Tailscale. Log in only if Omer gives the password himself, then run
     `systemctl --failed` and `journalctl -b -p err`, and roll back with
     `/run/current-system/bin/switch-to-configuration` of the previous
     generation as in [Roll back a running host](#roll-back-a-running-host);
   - a kernel panic, an initrd emergency shell or a frozen boot means the new
     generation does not boot; go to step 3.
3. Reset the box from SCP (its reset or restart control, not power off and
   reinstall). Watch the console: Limine shows its menu for a few seconds.
   Press a key to stop the countdown, open the previous `Generation <number>`
   entry and pick `Default`. With agent-browser, send keys to the console with
   `press ArrowDown` and `press Enter` after a click on the console canvas.
4. Once SSH answers again, keep the box on that generation: pause
   `nixos-upgrade.timer` and drop the newer generations as steps 2 and 3 of
   [Keep a generation on a Limine host](#keep-a-generation-on-a-limine-host)
   show, because Limine always boots the
   newest generation and the hourly install would build the broken `main`
   again and reboot into it in the next night window.
5. Open an issue with the broken `main` commit, the screenshots' findings and
   the first error of `journalctl -b -1 -p err`, and tell Omer the timer stays
   paused until a fixed `main` lands.
