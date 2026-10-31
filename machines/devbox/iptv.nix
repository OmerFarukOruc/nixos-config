{
  config,
  lib,
  pkgs,
  ...
}:
let
  secrets = ../../secrets/devbox-iptv.yaml;
  keys = [
    "provider-url"
    "provider-username"
    "provider-password"
    "client-password"
  ];
  envName = key: "IPTV_" + lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] key);
  secretName = key: "iptv-${key}";
  env = key: "\${env:${envName key}}";
  port = 8901;
  target = "provider";
  checkEnv = pkgs.writeShellScript "tuliprox-check-env" ''
    for name in ${toString (map envName keys)}; do
      value=''${!name-}
      inner=''${value#\"}
      inner=''${inner%\"}
      if [[ $value != \"?*\" || $inner == *[\\\"]* ]]; then
        echo "tuliprox.env: $name must be a non-empty value without \\ or \"" >&2
        exit 1
      fi
    done
  '';
in
{
  nixpkgs.overlays = [ (import ../../overlays/tuliprox.nix) ];

  sops = {
    secrets = lib.genAttrs' keys (key: {
      name = secretName key;
      value = {
        sopsFile = secrets;
        inherit key;
      };
    });
    templates."tuliprox.env" = {
      content = lib.concatMapStrings (
        key: "${envName key}=\"\\\"${config.sops.placeholder.${secretName key}}\\\"\"\n"
      ) keys;
      restartUnits = [ "tuliprox.service" ];
    };
  };

  services.tuliprox = {
    enable = true;
    systemSettings = {
      api = {
        host = "0.0.0.0";
        inherit port;
      };
      update_on_boot = true;
      schedules = [ { schedule = "0 0 5,17 * * * *"; } ];
      web_ui.enabled = false;
      reverse_proxy.stream = {
        retry = true;
        grace_period_millis = 0;
      };
    };
    sourceSettings.sources = [
      {
        inputs = [
          {
            name = "provider";
            type = "xtream";
            url = env "provider-url";
            username = env "provider-username";
            password = env "provider-password";
            headers."User-Agent" = "Lavf/61.7.100";
            max_connections = 1;
          }
        ];
        targets = [
          {
            name = target;
            filter = ''Group ~ ".*"'';
            output = [ { type = "xtream"; } ];
          }
        ];
      }
    ];
    apiProxySettings = {
      server = [
        {
          name = "default";
          protocol = "http";
          host = "devbox";
          port = toString port;
          timezone = config.time.timeZone;
          message = "IPTV through devbox";
        }
      ];
      user = [
        {
          inherit target;
          credentials = [
            {
              username = "omer";
              password = env "client-password";
              proxy = "reverse";
            }
          ];
        }
      ];
    };
  };

  systemd.services.tuliprox = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      EnvironmentFile = config.sops.templates."tuliprox.env".path;
      ExecStartPre = [ checkEnv ];
    };
  };
}
