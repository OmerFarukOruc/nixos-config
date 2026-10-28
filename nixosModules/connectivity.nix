{ config, lib, ... }:
let
  cfg = config.oruc.machine;
in
lib.mkIf (cfg.kind == "workstation") {
  networking.networkmanager = {
    enable = true;
    wifi.powersave = lib.mkIf (cfg.formFactor == "laptop") false;
    # Without a check URI, NetworkManager guesses connectivity once at activation
    # and never rechecks, so the tray shows "!" after a VPN goes down.
    settings.connectivity.uri = "http://nmcheck.gnome.org/check_network_status.txt";
  };

  services.tailscale.extraSetFlags = [
    "--accept-dns=true"
    "--ssh=false"
  ];

  services.openssh = lib.mkIf cfg.features.remoteAccess {
    enable = true;
    authorizedKeysInHomedir = false;
    settings = {
      PermitRootLogin = "no";
    };
  };

  security.sudo.wheelNeedsPassword = lib.mkIf cfg.features.remoteAccess false;

  systemd.services.sshd = lib.mkIf cfg.features.remoteAccess {
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
  };

  users.users.oruc.extraGroups = [ "networkmanager" ];
}
