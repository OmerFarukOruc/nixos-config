
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
machine.succeed("test -e /var/lib/systemd/linger/sl-factory")
FACTORY_ACCOUNTS = ["own-team", "work1", "work1-team", "work2", "work2-team"]
for config_dir in ["/home/sl-factory/.claude", *(f"/home/sl-factory/.claude-accounts/{name}" for name in FACTORY_ACCOUNTS)]:
    for reviewer_file in ["agents/code-reviewer.md", "agents/comment-sicko.md", "skills/ub-mode/SKILL.md", "skills/thermo-nuclear-code-quality-review/SKILL.md"]:
        machine.succeed(f"runuser -u sl-factory -- test -f {config_dir}/{reviewer_file} -a -s {config_dir}/{reviewer_file}")
for rule_file in ["core.md", "testing-discipline.md", "engineering.md", "reviews.md"]:
    machine.succeed(f"runuser -u sl-factory -- test -f /home/sl-factory/.claude/shared/{rule_file} -a -s /home/sl-factory/.claude/shared/{rule_file}")
for tool in ["codex-ask", "wait-exit", "sandbox-run", "dryer", "codex"]:
    machine.succeed(f"runuser -l sl-factory -c 'command -v {tool}'")
machine.succeed("runuser -u sl-factory -- bash -c 'mkdir -p /tmp/agents && mktemp -d -p /tmp/agents probe-review.XXXXXX'")
machine.fail("runuser -u sl-factory -- ls /tmp/agents")
machine.succeed(f"runuser -u {BOX_USER} -- bash -c 'umask 022 && mkdir /tmp/agents/box-probe && echo secret > /tmp/agents/box-probe/note'")
machine.succeed("test $(( $(stat -c %a /tmp/agents/box-probe) % 10 )) = 0")
machine.fail("runuser -u sl-factory -- cat /tmp/agents/box-probe/note")
machine.succeed(f"runuser -u {BOX_USER} -- ls /tmp/agents | grep -Fx box-probe")
for name in FACTORY_ACCOUNTS:
    machine.succeed(f"test -f /home/sl-factory/.claude-{name}/.claude-profile")
machine.succeed("systemctl list-timers claude-tools-usage-factory.timer | grep -F claude-tools-usage-factory.timer")
machine.succeed("systemctl start claude-tools-usage-factory.service")
machine.succeed("test $(stat -c %U:%a /home/sl-factory/.config/claude-tools/accounts.json) = sl-factory:600")
machine.fail("grep -F remote_hosts /home/sl-factory/.config/claude-tools/accounts.json")
for name in FACTORY_ACCOUNTS:
    machine.succeed(f"grep -F '\"{name}\"' /home/sl-factory/.cache/claude-tools/usage.json")
machine.succeed("test $(sysctl -n dev.tty.legacy_tiocsti) = 0")
machine.succeed(f"sudo -l -U {BOX_USER} | grep -F -e 'Defaults>sl-factory' | grep -F -e '!use_pty'")
machine.fail(f"sudo -l -U {BOX_USER} | sed -n '/^Matching Defaults/,/^$/p' | grep -F -e use_pty")
machine.succeed("iptables -S sl-factory-out | grep -F -e '-d 100.127.140.73/32 -o tailscale0 -p tcp -m tcp --dport 443 -j RETURN'")
machine.succeed("runuser -u omer -- timeout 5 bash -c 'read -r line < /dev/tcp/127.0.0.1/2222; [[ $line == SSH-2.0-* ]]'")
machine.fail("runuser -u sl-factory -- timeout 5 bash -c 'read -r line < /dev/tcp/127.0.0.1/2222'")


def fence_intact():
    uid = machine.succeed("id -u sl-factory").strip()
    for tool in ("iptables", "ip6tables"):
        machine.succeed(f"test $({tool} -S OUTPUT | grep -Fxc -e '-A OUTPUT -m owner --uid-owner {uid} -j sl-factory-out') = 1")
        machine.succeed(f"test $({tool} -S sl-factory-out | grep -Fc -e '-o lo -j REJECT') = 1")
        machine.succeed(f"test $({tool} -S sl-factory-out | grep -Fc -e '-o tailscale0 -j REJECT') = 1")
        machine.succeed(f"{tool} -S INPUT | grep -Fx -e '-A INPUT -j nixos-fw'")


machine.succeed(
    """cat > /tmp/fence-probe.sh <<'EOF'
for _ in {1..64}; do
  while [ ! -e /tmp/fence-probe.stop ]; do
    if (: < /dev/tcp/127.0.0.1/2222) 2>/dev/null; then echo leak; else echo blocked; fi
  done &
done
wait
EOF
chmod 755 /tmp/fence-probe.sh
systemd-run --quiet --unit=fence-probe --uid=sl-factory --property=StandardOutput=file:/tmp/fence-probe.out bash /tmp/fence-probe.sh"""
)
machine.wait_until_succeeds("test $(wc -l < /tmp/fence-probe.out) -ge 64")
fence_intact()
for _ in range(3):
    before = int(machine.succeed("wc -l < /tmp/fence-probe.out"))
    machine.succeed("systemctl reload firewall")
    machine.wait_until_succeeds(f"test $(wc -l < /tmp/fence-probe.out) -gt {before}")
    fence_intact()
machine.succeed("touch /tmp/fence-probe.stop")
machine.wait_until_succeeds("! systemctl is-active --quiet fence-probe")
machine.succeed("test $(grep -c blocked /tmp/fence-probe.out) -gt 0")
machine.succeed("! grep -q leak /tmp/fence-probe.out")

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
