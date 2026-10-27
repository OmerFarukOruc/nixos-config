# Tailscale and the firewall around it, for every host. A workstation adds its
# flags and SSH in connectivity.nix, a server in server-access.nix.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  securityTailscale =
    inputs.nixpkgs-security.legacyPackages.${pkgs.stdenv.hostPlatform.system}.tailscale;
in
{
  services.tailscale = {
    enable = true;
    package =
      if lib.versionOlder pkgs.tailscale.version securityTailscale.version then
        securityTailscale
      else
        pkgs.tailscale;
    # Opens only Tailscale's own UDP port.
    openFirewall = true;
  };

  # tailscaled-set runs `tailscale set` with extraSetFlags as a oneshot when
  # tailscaled starts, so a switch that changes the flags left them unapplied
  # until the next boot. Kept active, it restarts on a switch that changes it,
  # and PartOf runs it again whenever tailscaled restarts.
  systemd.services.tailscaled-set = lib.mkIf (config.services.tailscale.extraSetFlags != [ ]) {
    partOf = [ "tailscaled.service" ];
    serviceConfig.RemainAfterExit = true;
  };

  networking.firewall = {
    enable = true;
    trustedInterfaces = [ config.services.tailscale.interfaceName ];
  };

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
