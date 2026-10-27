# The boot test of risoluto-dev-1 (scripts/boot-server-vm-on-rog.sh): the host's
# disko image, built from the host with these changes only.
#
# - The sops file holds test values under the real key names, encrypted for the
#   age key of an SSH key that this build makes, because the box's own SSH host
#   key is not in the build. sops-nix reads it as it reads the host key. The
#   network values are those of QEMU's user networking.
# - The disk is 16 GiB instead of the box's 2 TiB; the layout takes the rest of
#   it as before.
# - The kernel logs to the serial port, and server-vm-report writes the state
#   of the units, disk, users and network to it, then powers the VM off.
#
# Takes the root flake; returns { image, qemu, ovmf, drvPath }.
flake:
let
  host = flake.nixosConfigurations.risoluto-dev-1;
  inherit (host) pkgs;

  secrets =
    pkgs.runCommand "server-vm-secrets"
      {
        nativeBuildInputs = [
          pkgs.mkpasswd
          pkgs.openssh
          pkgs.sops
          pkgs.ssh-to-age
        ];
      }
      ''
        mkdir $out
        ssh-keygen -q -t ed25519 -N "" -f $out/ssh_host_ed25519_key
        hash=$(mkpasswd -m sha-512 test)
        cat > plain.yaml <<YAML
        oruc-password-hash: '$hash'
        root-password-hash: '$hash'
        network-ipv4-address: 10.0.2.15/24
        network-ipv4-gateway: 10.0.2.2
        network-ipv6-address: fec0::15/64
        network-dns-1: 10.0.2.3
        network-dns-2: 10.0.2.3
        network-dns-3: fec0::3
        YAML
        sops --encrypt --age "$(ssh-to-age -i $out/ssh_host_ed25519_key.pub)" \
          --input-type yaml --output-type yaml plain.yaml > $out/secrets.yaml
      '';

  tailnetConf = "/run/sshd-tailnet.conf";

  test = host.extendModules {
    modules = [
      (
        { lib, pkgs, ... }:
        let
          report = pkgs.writeShellScript "server-vm-report" ''
            PATH=${
              lib.makeBinPath [
                pkgs.coreutils
                pkgs.gnugrep
                pkgs.iproute2
                pkgs.iptables
                pkgs.jq
                pkgs.kmod
                pkgs.openssh
                pkgs.procps
                pkgs.shadow
                pkgs.systemd
                pkgs.tailscale
                pkgs.util-linux
              ]
            }
            echo SERVER-VM-REPORT-BEGIN
            echo "firmware $([ -d /sys/firmware/efi ] && echo uefi || echo bios)"
            echo "cmdline $(cat /proc/cmdline)"
            for unit in sshd sshd-tailnet-listen tailscaled systemd-networkd qemu-guest-agent; do
              echo "unit $unit $(systemctl is-active $unit.service)"
            done
            echo "tailscale $(tailscale status --json | jq -r .BackendState)"
            sshd=${lib.getExe' pkgs.openssh "sshd"}
            echo "sshd listeners"
            ss -Htln | grep -E ':(22|2222) '
            echo "sshd effective for oruc"
            sshd_config() { $sshd -T -f /etc/ssh/sshd_config -C "user=$1,host=x,addr=127.0.0.1" 2>&1; }
            sshd_config oruc | grep -iE '^(port|listenaddress|permitrootlogin|allowusers|authorizedkeysfile|passwordauthentication) |rror'
            echo "sshd effective for root"
            sshd_config root | grep -iE '^authorizedkeysfile |rror'
            # No tailnet address exists in this VM, so sshd-tailnet-listen has
            # written nothing. Show what the Include adds once it does.
            echo "ListenAddress 10.0.2.15:2222" > ${tailnetConf}
            echo "sshd effective with a tailnet address"
            sshd_config oruc | grep -iE '^(port|listenaddress) |rror'
            : > ${tailnetConf}
            echo "root keys $(grep -c ssh-ed25519 /etc/ssh/authorized_keys.d/root)"
            echo "network"
            ip -br addr show scope global
            ip route show default
            ip -6 route show default
            networkctl list --no-legend
            resolvectl dns
            echo "sysctl"
            sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding vm.swappiness
            echo "firewall"
            iptables -S nixos-fw
            echo "mounts"
            findmnt -no TARGET,FSTYPE,OPTIONS /
            findmnt -no TARGET,FSTYPE,OPTIONS /boot
            lsblk -no NAME,SIZE,PARTTYPENAME /dev/vda
            ls /boot /boot/limine /boot/EFI/BOOT
            echo "users"
            id oruc
            grep '^oruc:' /etc/subuid /etc/subgid
            passwd -S oruc
            passwd -S root
            ls /var/lib/systemd/linger
            echo "console"
            echo "getty $(systemctl is-active getty@tty1.service) on tty $(cat /sys/class/tty/tty0/active)"
            ls /dev/dri /dev/fb0
            cat /sys/class/graphics/fb0/name
            lsmod | grep -E '^(bochs|drm|simpledrm|virtio_gpu)'
            journalctl -b -k --no-pager | grep -E 'fb0|vgaarb: setting'
            echo "journald and tmp"
            systemd-analyze cat-config systemd/journald.conf | grep SystemMaxUse
            systemd-tmpfiles --cat-config | grep -nE "^'?q'? '?/tmp'? "
            swapon --show=NAME,SIZE --noheadings
            echo SERVER-VM-REPORT-END
            # The runner takes a screendump of the VGA console meanwhile.
            sleep 5
            systemctl poweroff
          '';
        in
        {
          disko.devices.disk.main.imageSize = "16G";
          disko.memSize = 4096;

          sops = {
            validateSopsFiles = false;
            defaultSopsFile = lib.mkForce "${secrets}/secrets.yaml";
            age.sshKeyPaths = lib.mkForce [ "${secrets}/ssh_host_ed25519_key" ];
          };

          boot.kernelParams = [
            "console=tty0"
            "console=ttyS0,115200"
          ];

          systemd.services.server-vm-report = {
            wantedBy = [ "multi-user.target" ];
            wants = [ "network-online.target" ];
            after = [
              "network-online.target"
              "getty@tty1.service"
              "sshd.service"
              "sshd-tailnet-listen.service"
              "tailscaled.service"
              "systemd-networkd.service"
            ];
            serviceConfig = {
              Type = "oneshot";
              StandardOutput = "journal+console";
              ExecStart = report;
            };
          };
        }
      )
    ];
  };
in
{
  image = test.config.system.build.diskoImages;
  qemu = test.pkgs.qemu_kvm;
  ovmf = test.pkgs.OVMF.fd;
  drvPath = test.config.system.build.toplevel.drvPath;
}
