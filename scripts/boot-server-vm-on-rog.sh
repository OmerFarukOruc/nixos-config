#!/usr/bin/env bash
# usage: scripts/boot-server-vm-on-rog.sh [bios|uefi ...]
# Builds the disko image of risoluto-dev-1 with test secrets (ci/server-vm.nix)
# on nixos-rog, or on nixos-desktop while nixos-rog is offline, and boots it
# under SeaBIOS (bios) and under OVMF (uefi), by default both, with QEMU's
# standard VGA and user networking. The guest prints a report to its serial
# port (the report unit is in ci/server-vm.nix). The script exits 1 when a
# boot ends without the report, or when the report differs from what the host
# sets up: the firmware, the units, the address and routes from the sops
# template, the password and user settings, the listeners and effective
# settings of sshd, the firewall, the sysctls, the disk layout and the /tmp,
# journal and swap settings. It also fails when the VGA screen is black 3 s
# after the start.
#
# It proves that the host's own image boots through each firmware and that
# these settings arrive there. It does not prove the box's real secrets, which
# only the box's SSH host key opens, or the netcup network, or that Tailscale
# logs in, or the tailnet listener of sshd, which needs a tailnet address.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  echo "usage: $0 [bios|uefi ...]" >&2
  exit 2
}
modes=("$@")
((${#modes[@]})) || modes=(bios uefi)
for mode in "${modes[@]}"; do
  [[ $mode == bios || $mode == uefi ]] || usage
done

# shellcheck source=/dev/null
. scripts/lib/rog-copy.sh
rog_copy_open
rog_remote "${modes[@]}" <<'REMOTE'
set -euo pipefail
cd "$1"
shift

# The report came 13 to 15 s after the start under KVM on 2026-10-27; 300 s, a
# guess, bounds a boot that hangs.
boot_seconds=300
work=$(mktemp -d /tmp/server-vm.XXXXXXXX)
qemu_pid=
cleanup() {
  [[ -z $qemu_pid ]] || kill "$qemu_pid" 2>/dev/null || true
  rm -rf -- "$work"
}
trap cleanup EXIT

built=$(nix build --impure --no-link --json \
  --expr 'import ./ci/server-vm.nix (builtins.getFlake (toString ./.))' image qemu ovmf </dev/null)
image=$(jq -r '.[0].outputs.out' <<<"$built")/main.raw
qemu=$(jq -r '.[1].outputs.out' <<<"$built")/bin/qemu-system-x86_64
ovmf=$(jq -r '.[2].outputs | to_entries[0].value' <<<"$built")/FV
echo "image $image"

# lit FILE: prints how many hex digits of the picture in the PPM FILE are not
# zero, which is 0 for a black screen. The header is the first three lines.
lit() {
  tail -c +$(($(head -n 3 "$1" | wc -c) + 1)) "$1" | od -An -v -tx1 | tr -d ' 0\n' | wc -c
}

# screendump NAME: saves the VGA screen to $work/NAME.ppm through the monitor.
screendump() {
  exec 3<>"/dev/tcp/127.0.0.1/$monitor"
  printf 'screendump %s/%s.ppm\n' "$work" "$1" >&3
  sleep 1
  exec 3>&-
}

# boot MODE: boots the image once and prints the guest's report. Fails when the
# report is missing.
boot() {
  local mode=$1 log=$work/$mode.log args waited start
  monitor=$((20000 + RANDOM % 10000))
  args=(-enable-kvm -cpu host -m 4096 -smp 4 -vga std -display "vnc=unix:$work/vnc.sock" -no-reboot
    -serial "file:$log" -monitor "tcp:127.0.0.1:$monitor,server=on,wait=off"
    -drive "file=$image,if=virtio,format=raw,snapshot=on"
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0
    -device virtio-serial-pci -chardev "socket,id=qga,path=$work/qga.sock,server=on,wait=off"
    -device virtserialport,chardev=qga,name=org.qemu.guest_agent.0)
  if [[ $mode == uefi ]]; then
    cp "$ovmf/OVMF_VARS.fd" "$work/vars.fd"
    chmod u+w "$work/vars.fd"
    args+=(-drive "if=pflash,format=raw,unit=0,readonly=on,file=$ovmf/OVMF_CODE.fd"
      -drive "if=pflash,format=raw,unit=1,file=$work/vars.fd")
  fi
  : >"$log"
  start=$SECONDS
  "$qemu" "${args[@]}" &
  qemu_pid=$!
  # Limine's menu stays on the screen for 5 s, so a screendump 3 s after the
  # start shows whether the firmware's VGA output reached the screen.
  sleep 3
  # A QEMU that already ended leaves no monitor; the report check then fails.
  screendump "$mode-menu" || true
  until grep -q SERVER-VM-REPORT-END "$log"; do
    kill -0 "$qemu_pid" 2>/dev/null || break
    ((SECONDS - start < boot_seconds)) || break
    sleep 1
  done
  waited=$((SECONDS - start))
  wait_for_exit "$qemu_pid"
  qemu_pid=
  # The console shows the unit's output with the journal's prefix.
  tr -d '\r' <"$log" | sed -E 's/^\[ *[0-9.]+\] [^ ]*server-vm-report\[[0-9]+\]: //' >"$work/$mode.txt"
  echo "== $mode: serial log $(wc -l <"$work/$mode.txt") lines, the report came $waited s after the start"
  if [[ -s $work/$mode-menu.ppm ]]; then
    echo "vga screendump 3 s after the start: $(wc -c <"$work/$mode-menu.ppm") bytes, $(lit "$work/$mode-menu.ppm") hex digits not zero"
  fi
  sed -n '/SERVER-VM-REPORT-BEGIN/,/SERVER-VM-REPORT-END/p' "$work/$mode.txt"
}

# wait_for_exit PID: waits up to 30 s for the VM to power itself off.
wait_for_exit() {
  local step
  for ((step = 0; step < 30; step++)); do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 1
  done
  kill "$1" 2>/dev/null || true
}

# verdict MODE: checks the report of one boot against what the host sets up.
verdict() {
  local mode=$1 report=$work/$mode.txt failed=0 unit
  # expect WHAT GREP_ARGS...: fails the verdict unless grep finds the pattern.
  expect() {
    local what=$1
    shift
    grep -q "$@" -- "$report" || {
      echo "$mode: $what" >&2
      failed=1
    }
  }
  # reject WHAT GREP_ARGS...: fails the verdict when grep finds the pattern.
  reject() {
    local what=$1
    shift
    ! grep -q "$@" -- "$report" || {
      echo "$mode: $what" >&2
      failed=1
    }
  }
  [[ -s $work/$mode-menu.ppm && $(lit "$work/$mode-menu.ppm") -gt 1000 ]] || {
    echo "$mode: the standard VGA screen was black 3 s after the start" >&2
    failed=1
  }
  expect "the guest did not report firmware $mode" -Fx "firmware $mode"
  for unit in sshd sshd-tailnet-listen tailscaled systemd-networkd qemu-guest-agent; do
    expect "$unit is not active" -Fx "unit $unit active"
  done
  expect "the address of the sops template is missing" -F "10.0.2.15/24"
  expect "the IPv4 default route of the template is missing" -F "default via 10.0.2.2 dev"
  expect "the IPv6 default route is missing" -F "default via fe80::1 dev"
  expect "sshd does not listen on 127.0.0.1:22" -E "^LISTEN .* 127\.0\.0\.1:22 "
  reject "sshd listens beyond loopback" -E "^LISTEN .*(0\.0\.0\.0|\*|\[::\]):(22|2222) "
  expect "the Include of the tailnet address does not add port 2222" -Fx "ListenAddress 10.0.2.15:2222"
  expect "root may log in other than by key" -Fx "PermitRootLogin prohibit-password"
  expect "root reads more than the declared keys" -Fx "AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u"
  expect "oruc does not read ~/.ssh/authorized_keys" -Fx "AuthorizedKeysFile %h/.ssh/authorized_keys /etc/ssh/authorized_keys.d/%u"
  expect "root lacks its three declared keys" -Fx "root keys 3"
  expect "the password hash of oruc is not applied" -E "^oruc P "
  expect "the password hash of root is not applied" -E "^root P "
  expect "oruc has the wrong ids or groups" -Fx "uid=1003(oruc) gid=1003(oruc) groups=1003(oruc),1(wheel)"
  expect "oruc has the wrong subuid range" -Fx "/etc/subuid:oruc:100000:65536"
  expect "oruc has the wrong subgid range" -Fx "/etc/subgid:oruc:100000:65536"
  expect "oruc does not linger" -Fx oruc
  expect "IPv4 forwarding is off" -Fx "net.ipv4.ip_forward = 1"
  expect "IPv6 forwarding is off" -Fx "net.ipv6.conf.all.forwarding = 1"
  expect "vm.swappiness is not 100" -Fx "vm.swappiness = 100"
  expect "the firewall does not open Tailscale's UDP port" -Fx -e "-A nixos-fw -p udp -m udp --dport 41641 -j nixos-fw-accept"
  reject "the firewall opens a TCP port" -E -e "^-A nixos-fw .*-p tcp"
  expect "the BIOS boot partition is missing" -F "1M BIOS boot"
  expect "the ESP is not 4 GiB" -F "4G EFI System"
  expect "/boot lacks the masks 0077" -E "^/boot .*dmask=0077"
  expect "journald is not capped at 2G" -Fx "SystemMaxUse=2G"
  # systemd-tmpfiles takes the first rule for a path, and the report lists them
  # in the order it reads them.
  [[ $(grep -E "^[0-9]+:('q'|q) ('/tmp'|/tmp) " "$report" | head -n 1) == *7d* ]] || {
    echo "$mode: the /tmp rule of this host does not come first" >&2
    failed=1
  }
  expect "there is no zram swap" -E "^/dev/zram0 "
  expect "no getty on tty1" -Fx "getty active on tty tty1"
  return "$failed"
}

status=0
for mode in "$@"; do
  boot "$mode"
  if verdict "$mode"; then
    echo "$mode: the report matches the host"
  else
    status=1
  fi
done
exit "$status"
REMOTE
