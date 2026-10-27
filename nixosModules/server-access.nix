# How a server is reached: Tailscale with its SSH server and an exit node, and
# OpenSSH on loopback and the tailnet address only. The public interface keeps
# only Tailscale's UDP port (tailscale.nix).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.oruc.machine;
  tailscale = lib.getExe config.services.tailscale.package;
  tailnetConf = "/run/sshd-tailnet.conf";

  # The tailnet address is not in this public repository, and it exists only
  # while Tailscale is logged in, which can come after sshd starts: on a first
  # login, or after an outage of the control server. This loop reads the address
  # from tailscaled every 10 s (a guess) and, once tailscale0 holds an address
  # that differs from the last one written, writes it into the file that
  # sshd_config includes and reloads sshd, which then binds it. A tailscaled
  # that is stopped for a moment leaves the last address in place. Until the
  # first address, sshd listens on loopback only and Tailscale SSH is the way in.
  tailnetListen = pkgs.writeShellScript "sshd-tailnet-listen" ''
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.iproute2
        pkgs.systemd
      ]
    }
    current=
    while true; do
      addr=$(${tailscale} ip -4 2>/dev/null | head -n 1) || addr=
      if [[ -n $addr && $addr != "$current" ]] && ip -4 -o addr show dev ${config.services.tailscale.interfaceName} | grep -qwF -- "$addr"; then
        echo "ListenAddress $addr:2222" > ${tailnetConf}.new
        mv ${tailnetConf}.new ${tailnetConf}
        systemctl try-reload-or-restart sshd.service
        current=$addr
        echo "sshd listens on the tailnet address, port 2222"
      fi
      sleep 10
    done
  '';
in
lib.mkIf (cfg.kind == "server") {
  services.tailscale = {
    # Turns on IPv4 and IPv6 forwarding, which an exit node needs.
    useRoutingFeatures = "server";
    extraSetFlags = [
      "--ssh"
      "--advertise-exit-node"
      # The host's resolvers come from its network file.
      "--accept-dns=false"
    ];
  };

  # Nothing answers on the public interface, ping included.
  networking.firewall.allowPing = false;

  services.openssh = {
    enable = true;
    openFirewall = false;
    ports = [ 22 ];
    # Port 22 on the tailnet address belongs to Tailscale SSH. The tailnet
    # address on port 2222 comes from sshd-tailnet-listen.
    listenAddresses = [
      {
        addr = "127.0.0.1";
        port = 22;
      }
    ];
    settings = {
      AuthenticationMethods = "publickey";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
      AllowUsers = [
        "root"
        "oruc"
      ];
      # As in connectivity.nix: a client that stopped answering for 45 s loses
      # its session, which frees the deploy lock it held.
      ClientAliveInterval = 15;
      ClientAliveCountMax = 3;
    };
    # oruc reads ~/.ssh/authorized_keys, which the Grok bots' login rewrites.
    # root reads only the keys declared here; the Match block must stay last.
    extraConfig = ''
      Include ${tailnetConf}
      Match User root
        AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u
    '';
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMV6Kg6JIDEOFDbA5ezTsHnxFq2fXzB75x0+tybHlB/h omer-all-devices"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPxGYj0ZCsUeUBn4HmOsV1yUoLPJrxPFWblNSK9P/bE omer@risoluto-dev-1"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJPOeV4rvCOb2SRldAvkVh6fyEb/p/c2rzoZkUroBYhr co-admin"
  ];

  systemd.services.sshd = {
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
  };

  systemd.services.sshd-tailnet-listen = {
    description = "Add the tailnet address to the listeners of sshd";
    wantedBy = [ "multi-user.target" ];
    after = [
      "tailscaled.service"
      "sshd.service"
    ];
    serviceConfig = {
      ExecStart = tailnetListen;
      Restart = "always";
      RestartSec = 10;
    };
  };
}
