# First install of nixos-desktop

Run on nixos-desktop from the NixOS minimal ISO, wired to the LAN. NixOS goes
on the WD SN850X. The Samsung 990 PRO holds Windows and its own ESP; leave it
alone.

Step 3 erases the WD disk, the old system's `/home` included, so copy off
what you keep first. Before you start, have these ready:

- A copy of the SSH host keys of the system this install replaces
  (`ssh_host_ed25519_key`, `ssh_host_rsa_key`, `ssh_host_ecdsa_key` and their
  `.pub` files) on nixos-rog. `secrets/nixos-desktop.yaml` is encrypted to the
  age key derived from `ssh_host_ed25519_key.pub`, so sops-nix decrypts it on
  the first boot only with these keys. `.sops.yaml` holds that age key for
  nixos-desktop and for nixos-rog, and `programs.ssh.knownHosts` in
  `nixosModules/common.nix` holds the host keys of nixos-desktop,
  nixos-latitude and nixos-rog, so the scripts and deploys that SSH from one
  host to another, or from a host to itself, need no key accepted by hand.
  Putting the old keys back keeps both files valid. A host reinstalled with
  new keys needs its `.sops.yaml` entry re-derived and its `knownHosts` line
  changed.
- The commit to install, pushed to GitHub. The ISO downloads it over HTTPS,
  because the repository is public and nixos-rog accepts nothing from the LAN.

1. In the firmware setup (Del at the MSI logo), keep the boot mode UEFI and
   set Secure Boot to Disabled, because the firmware refuses the USB stick
   while it is on. Boot the USB stick; F11 at the MSI logo picks the boot
   device.
2. Become root and find the disk by its id, not its `nvme` number:

   ```
   sudo -i
   ls -l /dev/disk/by-id/ | grep -i sn850x
   DISK=/dev/disk/by-id/nvme-WD_BLACK_SN850X_1000GB_<serial>
   ```

3. Partition and format it. The GPT partition names `nixos-esp` and `nixos`
   are what `machines/nixos-desktop/hardware-configuration.nix` and
   [recovery.md](recovery.md#nixos-desktop) mount.

   ```
   wipefs -a "$DISK"
   parted "$DISK" -- mklabel gpt
   parted "$DISK" -- mkpart nixos-esp fat32 1MiB 4097MiB
   parted "$DISK" -- set 1 esp on
   parted "$DISK" -- mkpart nixos btrfs 4097MiB 100%
   udevadm settle
   mkfs.fat -F 32 -n BOOT /dev/disk/by-partlabel/nixos-esp
   mkfs.btrfs -f -L nixos /dev/disk/by-partlabel/nixos
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
   `nixosModules/common.nix`, and `ci/checks.sh` fails when a copy differs.

   ```
   export NIX_CONFIG='experimental-features = nix-command flakes
   extra-substituters = https://cache.lantian.pub/lantian https://cache.numtide.com
   extra-trusted-public-keys = lantian:WVGO7vsRMSEN+h7Lp7kv6SAmrkEXgUGbbXm7jMDjBuQ= niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g='
   curl -L https://github.com/OmerFarukOruc/nixos-config/archive/<commit>.tar.gz | tar xz -C /mnt/etc/nixos --strip-components=1
   nixos-generate-config --root /mnt --show-hardware-config > /tmp/generated.nix
   grep -A8 availableKernelModules /tmp/generated.nix
   install -d -m 0700 /mnt/var/lib/secure-boot
   nix shell nixpkgs#openssl --command openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 10950 \
     -subj '/CN=nixos-desktop Secure Boot/' \
     -keyout /mnt/var/lib/secure-boot/db.key -out /mnt/var/lib/secure-boot/db.pem
   nixos-install --flake /mnt/etc/nixos#nixos-desktop
   ```

   The boot loader install signs Limine with the key in
   `/mnt/var/lib/secure-boot` and fails without it. The firmware still holds
   the old system's certificate, so Secure Boot stays off until
   [Secure Boot](#secure-boot) below appends the new one.

   The committed `hardware-configuration.nix` mounts by partition name, so the
   install keeps it. Compare its `boot.initrd.availableKernelModules` with the
   generated list first. When the generated list has a module the file lacks,
   add it here and commit the same change to the repository after the first
   boot, because `deploy.sh` ships the committed file. `nixos-install` builds
   the system in `/mnt`, not in the ISO's memory-backed store, and asks for the
   root password at the end.

6. Set oruc's password, which unlocks the screen after the automatic login,
   then reboot and remove the USB stick:

   ```
   nixos-enter --root /mnt -c 'passwd oruc'
   reboot
   ```

7. On the first boot, Plasma logs oruc in and locks the screen. Unlock it,
   open a terminal, and join the tailnet with its tag:

   ```
   sudo tailscale up --ssh=false --advertise-tags=tag:desktop-relay
   ```

   Open the printed URL on any device and approve the machine. `tailscale up`
   resets the operator that `tailscaled-set` applied at boot, so apply it
   again:

   ```
   sudo systemctl restart tailscaled-set
   tailscale debug prefs | jq -r .OperatorUser
   ```

   It prints `oruc`. Then delete the node of the old system in the admin
   console.

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

   Do this after the host boots a generation that `deploy.sh` made. Then move
   the install copy of the repository out of `/etc/nixos`, so nothing builds
   that stale copy again
   ([Upgrade a host to main](deploy.md#upgrade-a-host-to-main)):

   ```
   ssh -t nixos-desktop 'sudo mv /etc/nixos /etc/nixos.install-copy'
   ```

10. Set up Omer's own credentials with
    [Per-host credentials](../home-manager/README.md#per-host-credentials): the
    shared SSH key, `gh auth login` and commit signing. The first switch
    clones nixos-config into `~/Desktop/workspace/nixos-config` through
    `agents-pull` ([agents/README.md](../agents/README.md)), so the agent
    config links resolve.

## Secure Boot

The record of nixos-desktop sets `secureBoot`, so every boot loader install
signs Limine with the key from step 5
([Inventory](architecture.md#inventory)). The firmware keeps its factory keys,
which Windows and its updates expect, and gets our certificate as one more
entry in `db`. Do this once NixOS boots with Secure Boot off, and again after
a BIOS update or a CMOS clear that drops the certificate.

1. Put the certificate on the ESP, where the firmware's file browser finds it:

   ```
   sudo openssl x509 -in /var/lib/secure-boot/db.pem -outform DER -out /boot/nixos-desktop-db.cer
   ```

2. In the firmware setup (Del at the MSI logo), under Settings > Security >
   Secure Boot:

   - Set "Secure Boot" to Enabled and "Secure Boot Mode" to Custom.
   - Set "Secure Boot Preset" to Maximum Security. The default,
     Hardware/OS Compatibility, runs an image that fails the check.
   - In Key Management, select the "Authorized Signatures (db)" row and pick
     "Append Key" from its menu. Answer "No" to the factory default, so the
     firmware asks for a file. Its list of file systems cuts every name short;
     the one that holds `nixos-desktop-db.cer` beside the folders `efi` and
     `limine` is the ESP of the WD disk. Pick that file, pick "Public Key
     Certificate" as its format, leave the owner GUID empty, and answer "Yes"
     to the update. The firmware answers "Append Key success", and the row
     reads 7 keys and "Mixed" instead of 6 and "Factory".

   The same menu holds "Delete Var", which empties `db` after one "Yes", and
   "Set New Var", which replaces `db`. Use neither. After a "Delete Var",
   "Set New Var" answered with "Yes" loads the factory `db` again; then append
   the certificate. Secure Boot Mode Standard also loads the factory keys
   again, so leave it at Custom. After any of these changes the "Vendor Keys"
   line reads "Modified".
3. Save with F10. The Limine menu appears, and on NixOS this prints
   `Secure Boot: enabled (user)`:

   ```
   bootctl status 2>/dev/null | grep -m1 'Secure Boot'
   ```

[recovery.md](recovery.md#secure-boot) covers a firmware that refuses Limine.
