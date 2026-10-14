# Wi-Fi driver option, NextDNS over TLS with a captive-portal switch, and TCP
# tuning, and the Tailscale operator.
{ config, pkgs, ... }:
let
  profile = config.sops.placeholder.nextdns-profile;
in
{
  # Disabling ASPM keeps the MT7925 from dropping its link, as on CachyOS.
  # Wi-Fi is the only way in, so this stays until a test without it passes.
  boot.extraModprobeConfig = ''
    options mt7925e disable_aspm=Y
  '';

  # browser-lend runs `tailscale serve` as oruc to lend Brave's debugging port
  # to risoluto-dev-1, and only the operator may change serve without sudo.
  # The list adds to the shared flags in nixosModules/connectivity.nix.
  services.tailscale.extraSetFlags = [ "--operator=oruc" ];

  services.resolved = {
    enable = true;
    settings.Resolve.DNSSEC = "allow-downgrade";
  };

  # DNS-over-TLS to the NextDNS profile. Domains=~. makes it the only route for
  # public names, so the Wi-Fi network's DNS servers never answer them; tailnet
  # names still go to MagicDNS by their longer suffix. Without the secret this
  # file does not exist and resolved uses the DHCP servers.
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

  boot.kernel.sysctl = {
    # Congestion control only shapes what this laptop sends.
    "net.ipv4.tcp_congestion_control" = "bbr";
    # Attaches to tailscale0 and wired links; Wi-Fi keeps mac80211's own queue.
    "net.core.default_qdisc" = "fq";
    # Room for QUIC receive and send buffers.
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    "net.ipv4.tcp_slow_start_after_idle" = 0;
    # Recovers from paths that drop ICMP "fragmentation needed".
    "net.ipv4.tcp_mtu_probing" = 1;
  };
}
