{ config, pkgs, ... }:
let
  profile = config.sops.placeholder.nextdns-profile;
in
{
  services.resolved = {
    enable = true;
    settings.Resolve.DNSSEC = "allow-downgrade";
  };

  sops.secrets.nextdns-profile = { };
  sops.templates."nextdns.conf" = {
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
