{
  config,
  inputs,
  lib,
  options,
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
    openFirewall = true;
  };

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
  # host here makes. The check keeps this valid on a nixpkgs from before that
  # commit, which has no such option.
  virtualisation.podman = lib.optionalAttrs (options.virtualisation.podman ? dns) {
    dns.openFirewall = false;
  };

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
