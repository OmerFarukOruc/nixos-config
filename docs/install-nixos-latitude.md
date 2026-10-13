# First install of nixos-latitude

Run on nixos-latitude from the NixOS minimal ISO. Before you start, serve the
committed files of this repository from fedora-desktop as a tarball with one
top-level directory, which step 5 strips:

```
mkdir -p /tmp/serve
git -C <nixos-config checkout> archive --format=tar.gz --prefix=nixos-config/ -o /tmp/serve/nixos-config.tar.gz HEAD
python3 -m http.server 8090 --directory /tmp/serve
```

`git archive` ships only committed files, so commit first. nixos-latitude fetches
the tarball from `<fedora-desktop-ip>:8090`, so fedora-desktop must accept TCP
port 8090 from the LAN. Stop the server after step 5.

1. Open the BIOS setup with F2 at the Dell logo. Disable Secure Boot, and set the
   boot mode to UEFI.
2. Boot the USB stick. F12 at the Dell logo picks the boot device.
3. Connect to Wi-Fi. The ISO uses NetworkManager, and `nmtui` does the same
   interactively:

   ```
   sudo -i
   nmcli device wifi connect 'SSID' password 'PASSWORD'
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

   The ESP is 4 GiB because every kept generation stores a kernel and an
   initrd on it. `keep-latest-n` in `nixosModules/common.nix` sets the count
   (5), and `nixosModules/bootloader.nix` applies it. `docs/recovery.md` mounts the
   labels `BOOT` and `nixos`. For a SATA disk, set `DISK=/dev/sda` and use
   `"${DISK}1"` and `"${DISK}2"` in the two `mkfs` lines.

5. Download this repository, replace its
   `machines/nixos-latitude/hardware-configuration.nix` with one generated for
   this disk, check that the flake evaluates and builds, and install. The ISO
   enables neither flakes nor this repository's binary caches. `NIX_CONFIG`
   turns both on, so the CachyOS kernel downloads instead of compiling on the
   live system. The keys are copies of the ones in `nixosModules/kernel.nix`
   and `nixosModules/common.nix`.

   ```
   export NIX_CONFIG='experimental-features = nix-command flakes
   extra-substituters = https://omerfarukoruc.cachix.org https://cache.numtide.com
   extra-trusted-public-keys = omerfarukoruc.cachix.org-1:6OxbnSmF+Agsn0w9aya633NTlxjxXAtsETYNcImB87c= niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g='
   mkdir -p /mnt/etc/nixos
   curl http://<fedora-desktop-ip>:8090/nixos-config.tar.gz | tar xz -C /mnt/etc/nixos --strip-components=1
   nixos-generate-config --root /mnt --show-hardware-config > /mnt/etc/nixos/machines/nixos-latitude/hardware-configuration.nix
   nix flake check --no-build --no-write-lock-file /mnt/etc/nixos
   nix build --no-link --no-write-lock-file /mnt/etc/nixos#nixosConfigurations.nixos-latitude.config.system.build.toplevel
   nixos-install --flake /mnt/etc/nixos#nixos-latitude
   ```

   `nixos-install` asks for the root password at the end.

6. Set the user password, reboot, and remove the USB stick:

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

8. Keep the generated disk ids in the repository. In the nixos-config checkout
   on fedora-desktop, copy the file the install generated:

   ```
   scp nixos-latitude:/etc/nixos/machines/nixos-latitude/hardware-configuration.nix machines/nixos-latitude/hardware-configuration.nix
   ```

   Commit it and deploy as [deploy.md](deploy.md#deploy) describes. `deploy.sh`
   ships this checkout, and step 4 gave the disks new UUIDs. The committed file
   still holds the old UUIDs, so the next generation could not mount root at
   the next boot.

   The header of this file points to `/etc/nixos/configuration.nix`. Ignore it.
   Host changes go in `machines/nixos-latitude/configuration.nix` and ship with
   `deploy.sh`.

9. After the laptop boots the deployed generation, delete the generation that
   `nixos-install` made:

   ```
   ssh -t nixos-latitude 'sudo nix-env -p /nix/var/nix/profiles/system --delete-generations 1'
   ```

   `nixos-install` registers that generation's GC root under `/mnt`, so the
   root goes stale after the first boot. angrr, which deletes old generations
   before each `nix-gc`, never sees it, and it would stay on disk for good.

Hardware facts and measured dead ends for this laptop are in
[nixos-latitude.md](nixos-latitude.md).
