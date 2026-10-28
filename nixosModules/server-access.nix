{ config, lib, ... }:
let
  cfg = config.oruc.machine;
in
lib.mkIf (cfg.kind == "server") {
  services.tailscale = {
    useRoutingFeatures = "server";
    extraSetFlags = [
      "--ssh"
      "--advertise-exit-node"
      "--accept-dns=false"
    ];
  };

  networking.firewall.allowPing = false;

  services.openssh = {
    enable = true;
    ports = [ 2222 ];
    settings = {
      PermitRootLogin = "prohibit-password";
      AllowUsers = [
        "root"
        "oruc"
      ];
    };
    # oruc also reads ~/.ssh/authorized_keys, where Omer adds the Grok bots'
    # key by hand.
    # root reads only the keys declared here; the Match block must stay last.
    extraConfig = ''
      Match User root
        AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u
    '';
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMV6Kg6JIDEOFDbA5ezTsHnxFq2fXzB75x0+tybHlB/h omer-all-devices"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGPxGYj0ZCsUeUBn4HmOsV1yUoLPJrxPFWblNSK9P/bE omer@risoluto-dev-1"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJPOeV4rvCOb2SRldAvkVh6fyEb/p/c2rzoZkUroBYhr co-admin"
  ];
}
