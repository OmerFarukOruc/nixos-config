# The host itself: units, firmware, network from the sops template, sshd,
# firewall, users and disk. Each module's own checks go in a file of their own.

for unit in ["sshd", "sshd-tailnet-listen", "tailscaled", "systemd-networkd"]:
    machine.wait_for_unit(f"{unit}.service")

# The disk boots through Limine under both firmwares; only OVMF has EFI variables.
if efi:
    machine.succeed("test -d /sys/firmware/efi")
else:
    machine.fail("test -d /sys/firmware/efi")
machine.succeed("test -e /boot/limine/limine-bios.sys")
machine.succeed("test -e /boot/EFI/BOOT/BOOTX64.EFI")

# The netcup console logs in on tty1.
machine.wait_for_unit("getty@tty1.service")

# The address and routes come from the sops template.
machine.wait_until_succeeds("ip -4 -o addr show scope global | grep -F 10.0.2.15/24")
machine.succeed("ip -4 route show default | grep -F 'via 10.0.2.2'")
machine.succeed("ip -6 route show default | grep -F 'via fe80::1'")

# sshd listens on loopback only until the tailnet address exists.
machine.succeed(r"ss -Htln | grep -E '127\.0\.0\.1:22 '")
machine.fail(r"ss -Htln | grep -E '(0\.0\.0\.0|\*|\[::\]):(22|2222) '")


def sshd_settings(user):
    out = machine.succeed(f"sshd -T -C user={user},host=x,addr=127.0.0.1")
    return set(out.lower().splitlines())


oruc = sshd_settings("oruc")
assert "permitrootlogin prohibit-password" in oruc, "root may log in other than by key"
assert "passwordauthentication no" in oruc, "password logins are on"
assert "allowusers root" in oruc and "allowusers oruc" in oruc, "AllowUsers is not root and oruc"
assert (
    "authorizedkeysfile %h/.ssh/authorized_keys /etc/ssh/authorized_keys.d/%u" in oruc
), "oruc does not read ~/.ssh/authorized_keys"
assert (
    "authorizedkeysfile /etc/ssh/authorized_keys.d/%u" in sshd_settings("root")
), "root reads more than the declared keys"
machine.succeed("test $(grep -c ssh-ed25519 /etc/ssh/authorized_keys.d/root) = 3")

# Users, with the password hashes that sops-nix decrypted before the users exist.
machine.succeed("passwd -S oruc | grep -E '^oruc P '")
machine.succeed("passwd -S root | grep -E '^root P '")
machine.succeed("id oruc | grep -Fx 'uid=1003(oruc) gid=1003(oruc) groups=1003(oruc),1(wheel)'")
machine.succeed("grep -Fx oruc:100000:65536 /etc/subuid")
machine.succeed("grep -Fx oruc:100000:65536 /etc/subgid")
machine.succeed("test -e /var/lib/systemd/linger/oruc")

# Exit node forwarding, the box's swappiness, and a firewall that opens only
# Tailscale's UDP port.
machine.succeed("test $(sysctl -n net.ipv4.ip_forward) = 1")
machine.succeed("test $(sysctl -n net.ipv6.conf.all.forwarding) = 1")
machine.succeed("test $(sysctl -n vm.swappiness) = 100")
machine.succeed("iptables -S nixos-fw | grep -Fx -e '-A nixos-fw -p udp -m udp --dport 41641 -j nixos-fw-accept'")
machine.fail("iptables -S nixos-fw | grep -E -e '^-A nixos-fw .*-p tcp'")

# The disk layout of disk.nix.
lsblk = machine.succeed("lsblk -no SIZE,PARTTYPENAME /dev/vda")
assert "1M BIOS boot" in lsblk, "the BIOS boot partition is missing"
assert "4G EFI System" in lsblk, "the ESP is not 4 GiB"
machine.succeed("findmnt -no FSTYPE,OPTIONS /boot | grep -E '^vfat .*dmask=0077'")
machine.succeed("findmnt -no FSTYPE / | grep -Fx ext4")

# Journal, /tmp and swap settings of the box.
machine.succeed("systemd-analyze cat-config systemd/journald.conf | grep -Fx SystemMaxUse=2G")
machine.succeed("systemd-tmpfiles --cat-config | grep -E \"^'?q'? '?/tmp'? \" | head -n 1 | grep -F 7d")
machine.succeed("swapon --show=NAME --noheadings | grep -E '^/dev/zram0'")
