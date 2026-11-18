{
  config,
  lib,
  pkgs,
  ...
}:
let
  autodetect = {
    enable = true;
    file = "/var/lib/zapret2/auto-hosts.txt";
  };
  autodetectTuning = [
    "--hostlist-auto-retrans-threshold=10"
    "--hostlist-auto-retrans-maxseq=1800"
    "--hostlist-auto-retrans-reset=0"
  ];
  # Microsoft's servers accept the TCP MD5 fake, which breaks TLS.
  # Their early RSTs also make autodetection add Microsoft hosts.
  microsoft = [
    "microsoftonline.com"
    "microsoft.com"
  ];
  discordHosts = [
    "discord.com"
    "discord.gg"
    "discord.media"
    "discordapp.com"
    "discordapp.net"
  ];
  discordVoicePorts = [
    {
      from = 19294;
      to = 19344;
    }
    {
      from = 50000;
      to = 50099;
    }
  ];
  discordVoiceFilter = lib.concatMapStringsSep "," (
    { from, to }: "${toString from}-${toString to}"
  ) discordVoicePorts;
  learnedDiscordProfile = priority: parameters: {
    inherit priority;
    hosts.autodetect = autodetect;
    hosts.include = discordHosts;
    hosts.exclude = microsoft;
    parameters = parameters ++ autodetectTuning;
  };
in
{
  assertions = [
    {
      assertion = config.services.zapret2.firewall.interfaces != null;
      message = "services.zapret2.firewall.interfaces must name the host's uplink.";
    }
  ];

  oruc.failurePopupUnits = [ "nfqws2@default" ];

  networking.nftables.enable = true;
  # Docker needs its nftables backend once nftables is on, and that backend
  # calls nft itself.
  virtualisation.docker.daemon.settings.firewall-backend = "nftables";
  virtualisation.docker.extraPackages = [ pkgs.nftables ];

  services.zapret2 = {
    enable = true;
    firewall = {
      tcpPorts = [
        80
        443
      ];
      udpPorts = lib.concatMap ({ from, to }: lib.range from to) discordVoicePorts;
    };
    profiles = {
      http = learnedDiscordProfile 1 [
        "--filter-tcp=80"
        "--filter-l7=http"
        "--payload=http_req"
        "--lua-desync=fake:blob=fake_default_http:tcp_md5"
        "--lua-desync=multisplit:pos=method+2"
      ];
      tls = learnedDiscordProfile 2 [
        "--filter-tcp=443"
        "--filter-l7=tls"
        "--payload=tls_client_hello"
        "--lua-desync=fake:blob=fake_default_tls:tcp_md5:repeats=1"
      ];
      discord-voice = {
        priority = 3;
        parameters = [
          "--filter-udp=${discordVoiceFilter}"
          "--filter-l7=stun,discord"
          "--payload=stun,discord_ip_discovery"
          "--lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2"
        ];
      };
    };
  };
}
