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
    oruc.failurePopupUnits = [ "usque" ];

    systemd.services.usque = {
      description = "Cloudflare WARP SOCKS5 proxy";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      preStart = ''
        if [[ ! -s config.json ]]; then
          rm -f config.json.new
          ${lib.getExe pkgs.usque} register --accept-tos --config config.json.new
          mv config.json.new config.json
        fi
      '';
      serviceConfig = {
        ExecStart = "${lib.getExe pkgs.usque} socks --bind 127.0.0.1 --port ${toString port}";
        Restart = "always";
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
