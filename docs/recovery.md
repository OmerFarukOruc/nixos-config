# Roll back or recover a host

## nixos-latitude

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
