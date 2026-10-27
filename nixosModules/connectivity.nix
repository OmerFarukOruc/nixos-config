{ config, lib, ... }:
let
  cfg = config.oruc.machine;
in
lib.mkIf (cfg.kind == "workstation") {
  networking.networkmanager = {
    enable = true;
    wifi.powersave = lib.mkIf (cfg.formFactor == "laptop") false;
  };

  services.tailscale.extraSetFlags = [
    "--accept-dns=true"
    "--ssh=false"
  ];

  services.openssh = lib.mkIf cfg.features.remoteAccess {
    enable = true;
    openFirewall = false;
    # Only the keys declared in this repository log in; ~/.ssh/authorized_keys
    # is ignored.
    authorizedKeysInHomedir = false;
    settings = {
      AuthenticationMethods = "publickey";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      # Closes the session of a client that stopped answering after 45 s, which
      # frees a deploy lock that session held.
      ClientAliveInterval = 15;
      ClientAliveCountMax = 3;
    };
  };

  # deploy.sh runs sudo over SSH without a terminal.
  security.sudo.wheelNeedsPassword = lib.mkIf cfg.features.remoteAccess false;

  systemd.services.sshd = lib.mkIf cfg.features.remoteAccess {
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
  };

  users.users.oruc.extraGroups = [ "networkmanager" ];
}
