{
  config,
  lib,
  ...
}:
{
  services.tailscale = {
    enable = true;
    openFirewall = true;
  };

  # NixOS blacklists ip_tables once nftables is on, so tailscaled must not
  # fall back to iptables.
  systemd.services.tailscaled.environment.TS_DEBUG_FIREWALL_MODE =
    lib.mkIf config.networking.nftables.enable "nftables";

  systemd.services.tailscaled-set = lib.mkIf (config.services.tailscale.extraSetFlags != [ ]) {
    partOf = [ "tailscaled.service" ];
    serviceConfig.RemainAfterExit = true;
  };

  networking.firewall = {
    enable = true;
    trustedInterfaces = [ config.services.tailscale.interfaceName ];
  };

  # Since nixpkgs cd731290f728, Podman opens port 53 on podman* for
  # aardvark-dns by default. Rootless networks run their DNS inside the user's
  # network namespace, so the host port serves only rootful networks, which no
  # host here makes.
  virtualisation.podman.dns.openFirewall = false;

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
          && lib.subtractLists [ "lo" config.services.tailscale.interfaceName ] fw.trustedInterfaces == [ ];
        message = "networking.firewall opens a port or trusts an interface besides Tailscale's.";
      }
    ];
}
