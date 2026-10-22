# First install of nixos-desktop

Run on nixos-desktop from the NixOS minimal ISO, wired to the LAN. NixOS goes
on the WD SN850X. The Samsung 990 PRO holds Windows and its own ESP; leave it
alone.

Before you start, have these ready:

- A copy of the SSH host keys of the system this install replaces
  (`ssh_host_ed25519_key`, `ssh_host_rsa_key`, `ssh_host_ecdsa_key` and their
  `.pub` files) on nixos-rog. `secrets/nixos-desktop.yaml` is encrypted to the
  age key derived from `ssh_host_ed25519_key.pub`, so sops-nix decrypts it on
  the first boot only with these keys.
- The commit to install, pushed to GitHub. The ISO downloads it over HTTPS,
  because the repository is public and nixos-rog accepts nothing from the LAN.

1. In the firmware setup (Del at the MSI logo), keep the boot mode UEFI and
   Secure Boot off. Boot the USB stick; F11 at the MSI logo picks the boot
   device.
2. Become root and find the disk by its id, not its `nvme` number:

   ```
   sudo -i
   ls -l /dev/disk/by-id/ | grep -i sn850x
   DISK=/dev/disk/by-id/nvme-WD_BLACK_SN850X_1000GB_<serial>
   ```

3. Partition and format it. The GPT partition names `nixos-esp` and `nixos`
   are what `machines/nixos-desktop/hardware-configuration.nix` mounts, and the
   file system labels `BOOT` and `nixos` are what [recovery.md](recovery.md)
   mounts.

   ```
   wipefs -a "$DISK"
   parted "$DISK" -- mklabel gpt
   parted "$DISK" -- mkpart nixos-esp fat32 1MiB 4097MiB
   parted "$DISK" -- set 1 esp on
   parted "$DISK" -- mkpart nixos btrfs 4097MiB 100%
   udevadm settle
   mkfs.fat -F 32 -n BOOT /dev/disk/by-partlabel/nixos-esp
   mkfs.btrfs -L nixos /dev/disk/by-partlabel/nixos
   mount /dev/disk/by-partlabel/nixos /mnt
   for sv in @nixos @nixos-home @nixos-nix @nixos-log; do btrfs subvolume create "/mnt/$sv"; done
   umount /mnt
   o=compress=zstd:1,noatime
   mount -o "subvol=@nixos,$o" /dev/disk/by-partlabel/nixos /mnt
   mkdir -p /mnt/{home,nix,var/log,boot,etc/ssh,etc/nixos}
   mount -o "subvol=@nixos-home,$o" /dev/disk/by-partlabel/nixos /mnt/home
   mount -o "subvol=@nixos-nix,$o" /dev/disk/by-partlabel/nixos /mnt/nix
   mount -o "subvol=@nixos-log,$o" /dev/disk/by-partlabel/nixos /mnt/var/log
   mount -o umask=077 /dev/disk/by-partlabel/nixos-esp /mnt/boot
   ```

   The ESP is 4 GiB because every kept generation stores a kernel and an
   initrd on it ([install-nixos-latitude.md](install-nixos-latitude.md) step
   4 has the count).

4. Put the old host keys in place. Start sshd on the ISO with a temporary root
   password, and push the keys from nixos-rog, which may open connections to
   the LAN:

   ```
   passwd
   systemctl start sshd
   ip -4 -br addr
   ```

   On nixos-rog, with the copy in `<keys dir>`:

   ```
   scp <keys dir>/ssh_host_* root@<installer-ip>:/mnt/etc/ssh/
   ```

   Back on the ISO, set their modes:

   ```
   chmod 600 /mnt/etc/ssh/ssh_host_*_key
   chmod 644 /mnt/etc/ssh/ssh_host_*_key.pub
   ```

5. Download the commit and install. `NIX_CONFIG` turns on flakes and this
   repository's caches, so the CachyOS kernel downloads instead of compiling;
   the keys are copies of the ones in `nixosModules/kernel.nix` and
   `nixosModules/common.nix`.

   ```
   export NIX_CONFIG='experimental-features = nix-command flakes
   extra-substituters = https://omerfarukoruc.cachix.org https://cache.numtide.com
   extra-trusted-public-keys = omerfarukoruc.cachix.org-1:6OxbnSmF+Agsn0w9aya633NTlxjxXAtsETYNcImB87c= niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g='
   curl -L https://github.com/OmerFarukOruc/nixos-config/archive/<commit>.tar.gz | tar xz -C /mnt/etc/nixos --strip-components=1
   nixos-generate-config --root /mnt --show-hardware-config > /tmp/generated.nix
   grep -A8 availableKernelModules /tmp/generated.nix
   nix build --no-link --no-write-lock-file /mnt/etc/nixos#nixosConfigurations.nixos-desktop.config.system.build.toplevel
   nixos-install --flake /mnt/etc/nixos#nixos-desktop
   ```

   The committed `hardware-configuration.nix` mounts by partition name, so the
   install keeps it. Compare its `boot.initrd.availableKernelModules` with the
   generated list first, and add any module the generated list has. `nixos-install`
   asks for the root password at the end.

6. Set oruc's password, which unlocks the screen after the automatic login,
   then reboot and remove the USB stick:

   ```
   nixos-enter --root /mnt -c 'passwd oruc'
   reboot
   ```

7. On the first boot, Plasma logs oruc in and locks the screen. Unlock it,
   open a terminal, and join the tailnet with the tag that the tailnet policy
   allows to be an exit node:

   ```
   sudo tailscale up --ssh=false --advertise-tags=tag:desktop-relay
   ```

   Open the printed URL on any device and approve the machine. In the admin
   console, approve its exit node, and delete the node of the old system.
   `tailscaled-set` adds `--advertise-exit-node` and `--operator=oruc` each time
   tailscaled starts.

8. From nixos-rog, check that sops-nix decrypted the secrets and that the host
   runs what was installed:

   ```
   ssh nixos-desktop 'sudo test -s /run/secrets/nextdns-profile && echo decrypted; resolvectl status | grep -m1 DNSOverTLS'
   ```

   When the secret is missing, the host keys of step 4 are not the ones the
   file is encrypted to.

9. Delete the generation that `nixos-install` made, as step 9 of
   [install-nixos-latitude.md](install-nixos-latitude.md) explains:

   ```
   ssh -t nixos-desktop 'sudo nix-env -p /nix/var/nix/profiles/system --delete-generations 1'
   ```

   Do this after the host boots a generation that `deploy.sh` made.
