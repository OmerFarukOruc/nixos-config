# DNS-over-TLS to Omer's NextDNS profile, with a switch for captive portals.
# The host imports this file and sops-nix, and its secrets file holds
# nextdns-profile.
{ config, pkgs, ... }:
let
  profile = config.sops.placeholder.nextdns-profile;
in
{
  services.resolved = {
    enable = true;
    settings.Resolve.DNSSEC = "allow-downgrade";
  };

  # Domains=~. makes NextDNS the only route for public names, so the network's
  # DNS servers never answer them; tailnet names still go to MagicDNS by their
  # longer suffix. Without the secret this file does not exist and resolved
  # uses the DHCP servers.
  #
  # The profile must allowlist risoluto.dev; docs/nixos-rog.md (DNS) says why.
  sops.secrets.nextdns-profile = { };
  sops.templates."nextdns.conf" = {
    # resolved reads its configuration as systemd-resolve.
    group = "systemd-resolve";
    mode = "0440";
    restartUnits = [ "systemd-resolved.service" ];
    content = ''
      [Resolve]
      DNS=45.90.28.0#${profile}.dns.nextdns.io
      DNS=45.90.30.0#${profile}.dns.nextdns.io
      DNSOverTLS=yes
      Domains=~.
    '';
  };
  environment.etc."systemd/resolved.conf.d/nextdns.conf".source =
    config.sops.templates."nextdns.conf".path;

  # A Wi-Fi sign-in page (hotel, cafe) often blocks DNS-over-TLS until login.
  # `sudo captive-dns on` adds a drop-in under /run that sorts after
  # nextdns.conf, clears the NextDNS servers and uses the network's own DNS in
  # plain text. `sudo captive-dns off` or a reboot restores NextDNS.
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "captive-dns";
      text = ''
        dropin=/run/systemd/resolved.conf.d/zz-captive-dns.conf
        case ''${1:-status} in
          on)
            mkdir -p "''${dropin%/*}"
            printf '%s\n' '[Resolve]' 'DNS=' 'Domains=' 'DNSOverTLS=no' >"$dropin"
            systemctl restart systemd-resolved
            echo "Plain DNS from the network until 'captive-dns off' or a reboot."
            ;;
          off)
            rm -f "$dropin"
            systemctl restart systemd-resolved
            echo "DNS-over-TLS to NextDNS again."
            ;;
          status)
            if [[ -e $dropin ]]; then echo on; else echo off; fi
            ;;
          *)
            echo "usage: captive-dns on|off|status" >&2
            exit 64
            ;;
        esac
      '';
    })
  ];
}
