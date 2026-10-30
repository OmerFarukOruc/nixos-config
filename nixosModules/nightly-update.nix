{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.oruc.nightlyUpdate;
  unit = "nightly-update";
in
{
  options.oruc.nightlyUpdate = {
    enable = lib.mkEnableOption "the nightly run that moves the inputs and apps, builds every host and pushes what passed to main";
    githubTokenFile = lib.mkOption {
      type = lib.types.str;
      example = "/run/secrets/github-push-token";
      description = "A file that holds a GitHub token with Contents and Issues write access to this repository.";
    };
  };

  config = lib.mkIf cfg.enable {
    oruc.telemetry.journalUnits = [ "${unit}.service" ];

    users.users.${unit} = {
      isSystemUser = true;
      group = unit;
      home = "/var/lib/${unit}";
    };
    users.groups.${unit} = { };

    systemd.services.${unit} = lib.mkMerge [
      (import ./deploy-unit.nix { inherit config pkgs; } {
        name = unit;
        script = ../scripts/nightly-update.sh;
        user = unit;
        inherit (cfg) githubTokenFile;
      })
      {
        description = "Move the inputs and apps, build every host and push what passed to main";
        environment.HOME = "/var/lib/${unit}";
        serviceConfig.TimeoutStartSec = lib.mkForce "4h30min";
      }
    ];

    systemd.timers.${unit} = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 21:15:00 UTC";
        Persistent = false;
        RandomizedDelaySec = "10min";
      };
    };
  };
}
