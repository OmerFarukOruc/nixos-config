{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.oruc.machine;
  securityTailscale =
    inputs.nixpkgs-security.legacyPackages.${pkgs.stdenv.hostPlatform.system}.tailscale;
in
lib.mkIf (cfg.kind == "workstation") {
  networking.networkmanager = {
    enable = true;
    wifi.powersave = lib.mkIf (cfg.formFactor == "laptop") false;
  };

  services.tailscale = {
    enable = true;
    package =
      if lib.versionOlder pkgs.tailscale.version securityTailscale.version then
        securityTailscale
      else
        pkgs.tailscale;
    extraSetFlags = [
      "--accept-dns=true"
      "--ssh=false"
    ];
    # Opens only Tailscale's own UDP port.
    openFirewall = true;
  };

  # tailscaled-set runs `tailscale set` with extraSetFlags as a oneshot when
  # tailscaled starts, so a switch that changes the flags left them unapplied
  # until the next boot. Kept active, it restarts on a switch that changes it,
  # and PartOf runs it again whenever tailscaled restarts.
  systemd.services.tailscaled-set = {
    partOf = [ "tailscaled.service" ];
    serviceConfig.RemainAfterExit = true;
  };

  networking.firewall = {
    enable = true;
    trustedInterfaces = [ config.services.tailscale.interfaceName ];
  };

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

  # Outside tailscale0 the only open port is Tailscale's own UDP port. The
  # check covers the port lists and trusted interfaces only. allowPing,
  # extraInputRules and extraCommands pass unchecked, and Docker and zapret2
  # write their own nftables rules, which it cannot see.
  assertions =
    let
      fw = config.networking.firewall;
      closed =
        ports:
        ports.allowedTCPPorts == [ ]
        && ports.allowedTCPPortRanges == [ ]
        && ports.allowedUDPPortRanges == [ ];
    in
    [
      {
        assertion =
          closed fw
          && fw.allowedUDPPorts == [ config.services.tailscale.port ]
          && lib.all (ports: closed ports && ports.allowedUDPPorts == [ ]) (lib.attrValues fw.interfaces)
          # The firewall module always trusts lo.
          && lib.subtractLists [ "lo" config.services.tailscale.interfaceName ] fw.trustedInterfaces == [ ];
        message = "networking.firewall opens a port or trusts an interface besides Tailscale's.";
      }
    ];
}
