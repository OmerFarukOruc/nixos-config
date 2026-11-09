
import socket

for unit in ["sshd", "tailscaled", "systemd-networkd"]:
    machine.wait_for_unit(f"{unit}.service")

machine.fail("test -d /sys/firmware/efi")
machine.succeed("test -e /boot/limine/limine-bios.sys")
machine.succeed("test -e /boot/EFI/BOOT/BOOTX64.EFI")

machine.wait_for_unit("getty@tty1.service")

machine.wait_until_succeeds("ip -4 -o addr show scope global | grep -F 10.0.2.15/24")
machine.succeed("ip -4 route show default | grep -F 'via 10.0.2.2'")
machine.succeed("ip -6 route show default | grep -F 'via fe80::1'")

machine.succeed(r"ss -Htln | grep -E '(0\.0\.0\.0|\*):2222 '")
machine.succeed(r"ss -Htln | grep -E '\[::\]:2222 '")
machine.fail(r"ss -Htln | grep -E ':22 '")
machine.wait_until_succeeds("timeout 5 bash -c 'read -r line < /dev/tcp/127.0.0.1/2222; [[ $line == SSH-2.0-* ]]'")


def sshd_settings(user):
    out = machine.succeed(f"sshd -T -C user={user},host=x,addr=127.0.0.1")
    return set(out.lower().splitlines())


box_sshd = sshd_settings(BOX_USER)
assert "permitrootlogin prohibit-password" in box_sshd, "root may log in other than by key"
assert "passwordauthentication no" in box_sshd, "password logins are on"
assert "allowusers root" in box_sshd and f"allowusers {BOX_USER}" in box_sshd, f"AllowUsers is not root and {BOX_USER}"
assert (
    "authorizedkeysfile %h/.ssh/authorized_keys /etc/ssh/authorized_keys.d/%u" in box_sshd
), f"{BOX_USER} does not read ~/.ssh/authorized_keys"
assert (
    "authorizedkeysfile /etc/ssh/authorized_keys.d/%u" in sshd_settings("root")
), "root reads more than the declared keys"
machine.succeed(
    "f=/etc/ssh/authorized_keys.d/root; n=$(grep -c . $f) && [ $n -gt 0 ] && [ $(ssh-keygen -l -f $f | wc -l) = $n ]"
)

machine.succeed(f"passwd -S {BOX_USER} | grep -E '^{BOX_USER} P '")
machine.succeed("passwd -S root | grep -E '^root P '")
machine.succeed(f"id {BOX_USER} | grep -Fx 'uid=1003({BOX_USER}) gid=1003({BOX_USER}) groups=1003({BOX_USER}),1(wheel)'")
machine.succeed(f"grep -Fx {BOX_USER}:100000:65536 /etc/subuid")
machine.succeed(f"grep -Fx {BOX_USER}:100000:65536 /etc/subgid")
machine.succeed(f"test -e /var/lib/systemd/linger/{BOX_USER}")

machine.fail("grep -E '^sl-factory:' /etc/subuid /etc/subgid")
machine.succeed("test $(sysctl -n dev.tty.legacy_tiocsti) = 0")
machine.succeed("sudo -l -U omer | grep -F -e 'Defaults>sl-factory' | grep -F -e '!use_pty'")
machine.succeed("! sudo -l -U omer | grep -F -e 'Defaults:omer' | grep -F -e '!use_pty'")
machine.succeed("iptables -S sl-factory-out | grep -F -e '-o lo -j REJECT'")
machine.succeed("iptables -S sl-factory-out | grep -F -e '-d 100.127.140.73/32 -o tailscale0 -p tcp -m tcp --dport 443 -j RETURN'")
machine.succeed("iptables -S sl-factory-out | grep -F -e '-o tailscale0 -j REJECT'")
machine.succeed("ip6tables -S sl-factory-out | grep -F -e '-o lo -j REJECT'")
machine.succeed("ip6tables -S sl-factory-out | grep -F -e '-o tailscale0 -j REJECT'")
machine.succeed("runuser -u omer -- timeout 5 bash -c 'read -r line < /dev/tcp/127.0.0.1/2222; [[ $line == SSH-2.0-* ]]'")
machine.fail("runuser -u sl-factory -- timeout 5 bash -c 'read -r line < /dev/tcp/127.0.0.1/2222'")

machine.succeed("test $(sysctl -n net.ipv4.ip_forward) = 1")
machine.succeed("test $(sysctl -n net.ipv6.conf.all.forwarding) = 1")
machine.succeed("test $(sysctl -n vm.swappiness) = 100")
machine.succeed("iptables -S nixos-fw | grep -Fx -e '-A nixos-fw -p udp -m udp --dport 41641 -j nixos-fw-accept'")
machine.fail("iptables -S nixos-fw | grep -E -e '^-A nixos-fw .*-p tcp'")
machine.succeed("iptables -S nixos-fw | grep -Fx -e '-A nixos-fw -i tailscale0 -j nixos-fw-accept'")
machine.fail("ip6tables -S nixos-fw | grep -E -e '^-A nixos-fw .*-p tcp'")
machine.succeed("ip6tables -S nixos-fw | grep -Fx -e '-A nixos-fw -i tailscale0 -j nixos-fw-accept'")


def ssh_banner():
    try:
        with socket.create_connection(("127.0.0.1", 12222), timeout=5) as conn:
            return conn.recv(64)
    except OSError:
        return b""


machine.forward_port(12222, 2222)
assert not ssh_banner().startswith(b"SSH-"), "sshd answers outside the tailnet interface"
machine.succeed("iptables -I nixos-fw -p tcp --dport 2222 -j nixos-fw-accept")
retry(lambda _last_try: ssh_banner().startswith(b"SSH-"))
machine.succeed("iptables -D nixos-fw -p tcp --dport 2222 -j nixos-fw-accept")

lsblk = machine.succeed("lsblk -no SIZE,PARTTYPENAME /dev/vda")
assert "1M BIOS boot" in lsblk, "the BIOS boot partition is missing"
assert "4G EFI System" in lsblk, "the ESP is not 4 GiB"
machine.succeed("findmnt -no FSTYPE,OPTIONS /boot | grep -E '^vfat .*dmask=0077'")
machine.succeed("findmnt -no FSTYPE / | grep -Fx ext4")

machine.succeed("systemd-analyze cat-config systemd/journald.conf | grep -Fx SystemMaxUse=2G")
machine.succeed("systemd-tmpfiles --cat-config | grep -E \"^'?q'? '?/tmp'? \" | head -n 1 | grep -F 7d")
machine.succeed("swapon --show=NAME --noheadings | grep -E '^/dev/zram0'")
