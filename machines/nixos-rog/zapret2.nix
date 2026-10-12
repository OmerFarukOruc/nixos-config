# zapret2 rewrites the first packets of outgoing HTTP, TLS and QUIC connections
# on Wi-Fi, so DPI on the line cannot block them (Discord on the home line).
# Discord starts on the list; any other host joins it after zapret2 sees a
# connection to it fail three times.
{ pkgs, ... }:
let
  # The MT7925 card, rog's only network device.
  wifi = "wlp99s0";
  # The HTTP and TLS profiles add failing hosts here; QUIC only reads it.
  autoHosts = "/var/lib/zapret2/auto-hosts.txt";
  autodetect = {
    enable = true;
    file = autoHosts;
  };
  # Discord's domains start on the list, so the first visits do not have to
  # fail before zapret2 learns them. Subdomains match too.
  discord = [
    "discord.com"
    "discord.gg"
    "discord.media"
    "discordapp.com"
    "discordapp.net"
  ];
in
{
  oruc.verifyFacts.wifi = wifi;

  networking.nftables.enable = true;
  # NixOS blacklists ip_tables once nftables is on, so tailscaled must not
  # fall back to iptables, and Docker needs its nftables backend, which calls
  # nft itself.
  systemd.services.tailscaled.environment.TS_DEBUG_FIREWALL_MODE = "nftables";
  virtualisation.docker.daemon.settings.firewall-backend = "nftables";
  virtualisation.docker.extraPackages = [ pkgs.nftables ];

  services.zapret2 = {
    enable = true;
    firewall = {
      interfaces = [ wifi ];
      tcpPorts = [
        80
        443
      ];
      udpPorts = [ 443 ];
    };
    # The strategies CachyOS ran on this laptop.
    profiles = {
      http = {
        priority = 1;
        hosts.autodetect = autodetect;
        hosts.include = discord;
        parameters = [
          "--filter-tcp=80"
          "--filter-l7=http"
          "--payload=http_req"
          "--lua-desync=fake:blob=fake_default_http:tcp_md5"
          "--lua-desync=multisplit:pos=method+2"
        ];
      };
      tls = {
        priority = 2;
        hosts.autodetect = autodetect;
        hosts.include = discord;
        parameters = [
          "--filter-tcp=443"
          "--filter-l7=tls"
          "--payload=tls_client_hello"
          "--lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=1"
        ];
      };
      quic = {
        priority = 3;
        hosts.include = discord;
        parameters = [
          "--filter-udp=443"
          "--filter-l7=quic"
          "--hostlist=${autoHosts}"
          "--payload=quic_initial"
          "--lua-desync=fake:blob=fake_default_quic:repeats=6"
        ];
      };
    };
  };
  # The QUIC profile's list must exist before the first failure writes it.
  systemd.services."nfqws2@default".serviceConfig.ExecStartPre =
    "${pkgs.coreutils}/bin/touch ${autoHosts}";
}
