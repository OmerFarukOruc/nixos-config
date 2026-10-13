# Roll back or recover a host

- [Roll back a running host](#roll-back-a-running-host)
- [A host that does not boot](#a-host-that-does-not-boot)
- [A generation the boot menu does not list](#a-generation-the-boot-menu-does-not-list)
- [Boot the recovery entry](#boot-the-recovery-entry)
- [Repair the bootloader](#repair-the-bootloader)
- [Swap on nixos-latitude](#swap-on-nixos-latitude)
- [nixos-rog](#nixos-rog)

Each host keeps the newest 5 system generations, one from each of the last 7
days, the running one, and the booted one. The boot menu lists only the newest
5. angrr deletes the other generations before the weekly `nix-gc`. `nix-gc`
then deletes the unreachable store paths.

The systemd-boot menu in the sections below is the one on nixos-latitude.
nixos-rog uses Limine, which the [nixos-rog](#nixos-rog) section covers.

## Roll back a running host

To switch nixos-latitude back to its previous retained generation, run:

```sh
ssh -t nixos-latitude 'sudo nixos-rebuild switch --rollback'
```

systemd-boot then boots that generation by default, as long as the menu lists
it. On nixos-rog, Limine always boots the newest generation, so a rollback lasts
only until the next reboot. To keep it there, follow [nixos-rog](#nixos-rog).

## A host that does not boot

1. Use the local console.
2. In the systemd-boot menu, select an older NixOS generation.
3. After it starts, make that selected generation the next boot default:

   ```sh
   sudo /run/current-system/bin/switch-to-configuration boot
   ```

After a kernel panic, a watchdog reset or an unexplained stop on
nixos-latitude, read the files in
`/var/lib/systemd/pstore` when the platform kept them, then run
`journalctl -b -1`. See [nixos-latitude.md](nixos-latitude.md#an-unexplained-stop).

## A generation the boot menu does not list

To go back to a kept generation that the boot menu does not list, do these
steps:

1. On nixos-rog, first pause the updater. Otherwise its next update deploys
   `main` again.

   ```sh
   sudo systemctl mask --runtime --now oruc-auto-update.timer
   ```

   The mask lasts until the next reboot. Use a mask, not a stop, because the
   activation in step 2 may restart a timer that was only stopped. To resume
   updates earlier, run `sudo systemctl unmask --runtime oruc-auto-update.timer` and
   then `sudo systemctl start oruc-auto-update.timer`. The mask does not stop
   an update that is running. Run `systemctl is-active oruc-auto-update.service`
   and wait until it prints `inactive` before step 2.

2. Run these commands. The first one lists the generations. The second one
   makes the generation you picked the current one, and the third one activates
   it. Use the number of the generation you picked.

   ```sh
   sudo nix-env -p /nix/var/nix/profiles/system --list-generations
   sudo nix-env -p /nix/var/nix/profiles/system --switch-generation <number>
   sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
   ```

   The host now runs the picked generation. On nixos-rog, a reboot boots the
   newest generation again, because Limine always makes the newest generation of
   the system profile the default ([nixos-rog](#nixos-rog)). To make the picked
   generation the boot default, delete the newer generations and install the
   boot entries again:

   ```sh
   sudo nix-env -p /nix/var/nix/profiles/system --delete-generations <newer...>
   sudo /nix/var/nix/profiles/system/bin/switch-to-configuration boot
   ```

## Boot the recovery entry

The normal generation uses the selected CachyOS kernel and the themed greeter.
The `recovery` specialisation of each generation boots the kernel set in
`oruc.recovery.kernelPackages` (the stock kernel by default) with the stock
greeter (`nixosModules/recovery.nix`). nixos-rog sets it to
`linuxPackages_latest`; see [nixos-rog](#nixos-rog). A runtime switch cannot
load a different kernel, so recovery needs a reboot:

1. Reboot.
2. In the boot menu of nixos-latitude, select the `recovery` specialisation
   for the generation that you need. On nixos-rog, open the generation in the
   Limine menu and pick `recovery`.
3. Check the running kernel:

   ```sh
   uname -r
   ```

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

For nixos-rog, replace the three mount lines with mounts that follow
`machines/nixos-rog/hardware-configuration.nix`. Mount subvolume `@nixos` on
`/mnt`, `@nixos-nix` on `/mnt/nix`, and the ESP on `/mnt/boot`. The installer
has no checkout of this repository. Read the btrfs UUID and the ESP UUID from
that file on another machine, or run `lsblk -f` in the installer and take the
btrfs partition that holds `@nixos` and the vfat ESP:

```sh
mount -o subvol=@nixos /dev/disk/by-uuid/<btrfs uuid> /mnt
mkdir -p /mnt/nix /mnt/boot
mount -o subvol=@nixos-nix /dev/disk/by-uuid/<btrfs uuid> /mnt/nix
mount -o umask=077 /dev/disk/by-uuid/<ESP uuid> /mnt/boot
```

Then run the `nixos-enter`, `NIXOS_INSTALL_BOOTLOADER=1`, `exit` and `reboot`
lines. The Limine entries then come back after a BIOS update that cleared the
firmware boot entries.

## Swap on nixos-latitude

The installed Latitude disk has one ext4 root partition and no disk-backed
swap. It keeps its existing zram swap until a non-destructive swap-file or
offline repartition plan is chosen.

Zswap waits for the same storage decision, because NixOS needs a physical swap
device and rejects zswap with zram.

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

To go back to an older generation, open its `Generation <number>` entry in the
Limine boot menu and pick `Default`. Pick `recovery` there for the recovery
kernel.

Limine always makes the newest generation of the system profile the default,
whatever generation runs. To keep a generation that you picked in the Limine
menu as the default, do these steps:

1. Boot that generation from the Limine menu.
2. Pause the updater, as step 1 of
   [A generation the boot menu does not list](#a-generation-the-boot-menu-does-not-list)
   describes. Otherwise its next update deploys a new newest generation, and
   Limine boots that one. The pause lasts until the next reboot. After the
   reboot the updater runs again, and its next deploy of `main` becomes the
   newest generation and the Limine default, which undoes the pin. After each
   reboot, pause the updater again, but it may run first, because
   `Persistent=true` runs a missed hourly update soon after boot (on 2026-10-11
   it started about 2 minutes after boot). If an update already ran, the pin is
   lost; repeat steps 1 to 3.
3. Drop the newer generations and reinstall the boot entries:

   ```sh
   sudo nix-env -p /nix/var/nix/profiles/system --list-generations
   sudo nix-env -p /nix/var/nix/profiles/system --switch-generation <good>
   sudo nix-env -p /nix/var/nix/profiles/system --delete-generations <newer...>
   sudo /run/current-system/bin/switch-to-configuration boot
   ```

The firmware GPU mode must be Hybrid mode (see `CONTEXT.md`). In Integrated
mode the NVIDIA driver has no device.
