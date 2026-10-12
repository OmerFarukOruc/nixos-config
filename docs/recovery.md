# Roll back or recover a host

- [Roll back a running host](#roll-back-a-running-host)
- [A host that does not boot](#a-host-that-does-not-boot)
- [A generation the boot menu does not list](#a-generation-the-boot-menu-does-not-list)
- [Boot the stock kernel](#boot-the-stock-kernel)
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

To switch a running host back to its previous retained generation, run:

```sh
ssh -t nixos-latitude 'sudo nixos-rebuild switch --rollback'
```

## A host that does not boot

1. Use the local console.
2. In the systemd-boot menu, select an older NixOS generation.
3. After it starts, make that selected generation the next boot default:

   ```sh
   sudo /run/current-system/bin/switch-to-configuration boot
   ```

## A generation the boot menu does not list

To go back to a kept generation that the boot menu does not list, do these
steps:

1. On nixos-rog, first stop the updater. Otherwise its next update deploys
   `main` again:

   ```sh
   sudo systemctl mask --runtime --now oruc-auto-update.timer
   ```

2. Run these commands. The first one lists the generations. In the second one,
   use the number of the generation you picked. The commands make it the
   current and default generation.

   ```sh
   sudo nix-env -p /nix/var/nix/profiles/system --list-generations
   sudo nix-env -p /nix/var/nix/profiles/system --switch-generation <number>
   sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
   ```

## Boot the stock kernel

The normal generation uses the selected CachyOS kernel. A runtime switch cannot
load a different kernel, so stock-kernel recovery needs a reboot:

1. Reboot.
2. In the systemd-boot menu, select the `recovery` specialisation for the
   generation that you need.
3. Check the running kernel:

   ```sh
   uname -r
   ```

## Repair the bootloader

When the bootloader itself needs repair, do these steps:

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

To go back to an older generation, pick it in the Limine boot menu.

Limine always makes the newest generation of the system profile the default,
whatever generation runs. To keep a generation that you picked in the Limine
menu as the default, do these steps:

1. Boot that generation from the Limine menu.
2. Drop the newer generations and reinstall the boot entries:

   ```sh
   sudo nix-env -p /nix/var/nix/profiles/system --list-generations
   sudo nix-env -p /nix/var/nix/profiles/system --switch-generation <good>
   sudo nix-env -p /nix/var/nix/profiles/system --delete-generations <newer...>
   sudo /run/current-system/bin/switch-to-configuration boot
   ```

The firmware GPU mode must be Hybrid mode (see `CONTEXT.md`). In Integrated
mode the NVIDIA driver has no device.
