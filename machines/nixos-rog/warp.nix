# Cloudflare WARP as a SOCKS5 proxy on loopback, through usque. It carries
# only the traffic of an app pointed at it; the WARP launchers in
# warp-launchers.nix are the fallback for when zapret2 does not get Discord
# through.
{ lib, pkgs, ... }:
let
  port = 1080;
in
{
  options.oruc.warpProxy = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    default = "socks5://127.0.0.1:${toString port}";
    description = "The address of the WARP SOCKS5 proxy, for the WARP launchers.";
  };

  config = {
    systemd.services.usque = {
      description = "Cloudflare WARP SOCKS5 proxy";
      wantedBy = [ "multi-user.target" ];
      # The first start registers a WARP device and keeps it in config.json.
      preStart = ''
        if [[ ! -f config.json ]]; then
          ${lib.getExe pkgs.usque} register --accept-tos
        fi
      '';
      serviceConfig = {
        ExecStart = "${lib.getExe pkgs.usque} socks --bind 127.0.0.1 --port ${toString port}";
        Restart = "always";
        # Offline at boot, registration fails until the network is up; the
        # delay grows so it does not ask Cloudflare every 3 s.
        RestartSec = 3;
        RestartSteps = 5;
        RestartMaxDelaySec = "5min";
        User = "usque";
        Group = "usque";
        StateDirectory = "usque";
        StateDirectoryMode = "0700";
        WorkingDirectory = "/var/lib/usque";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
      };
    };
    users.users.usque = {
      isSystemUser = true;
      group = "usque";
    };
    users.groups.usque = { };
  };
}
