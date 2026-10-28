{ config, pkgs, ... }:
let
  autoHosts = "/var/lib/zapret2/auto-hosts.txt";
  autodetect = {
    enable = true;
    file = autoHosts;
  };
  # Microsoft's servers accept the TCP MD5 fake, which breaks TLS.
  # Their early RSTs also make autodetection add Microsoft hosts.
  microsoft = [
    "microsoftonline.com"
    "microsoft.com"
  ];
  discord = [
    "discord.com"
    "discord.gg"
    "discord.media"
    "discordapp.com"
    "discordapp.net"
  ];
in
{
  assertions = [
    {
      assertion = config.services.zapret2.firewall.interfaces != null;
      message = "services.zapret2.firewall.interfaces must name the host's uplink.";
    }
  ];

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
      tcpPorts = [
        80
        443
      ];
      udpPorts = [ 443 ];
    };
    profiles = {
      http = {
        priority = 1;
        hosts.autodetect = autodetect;
        hosts.include = discord;
        hosts.exclude = microsoft;
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
        hosts.exclude = microsoft;
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
        hosts.exclude = microsoft;
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
  systemd.services."nfqws2@default".serviceConfig.ExecStartPre =
    "${pkgs.coreutils}/bin/touch ${autoHosts}";
}
