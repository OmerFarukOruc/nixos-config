# First install of nixos-latitude

Run on the laptop from the NixOS minimal ISO. fedora-desktop serves this repo
over the LAN at `<fedora-desktop-ip>:8090` during the install.

1. Open the BIOS setup with F2 at the Dell logo. Disable Secure Boot, and set the
   boot mode to UEFI.
2. Boot the USB stick. F12 at the Dell logo picks the boot device.
3. Connect to Wi-Fi:

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

   If the disk is SATA, its name is `/dev/sda`, and the partitions are `sda1` and `sda2`.

5. Download this repo, write the hardware file into the current `machines/`
   layout, evaluate the flake, and install:

   ```
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
