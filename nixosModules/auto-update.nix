{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.oruc.autoUpdate;
in
{
  options.oruc.autoUpdate = {
    enable = lib.mkEnableOption "the timer that deploys the newest main to this workstation every 2 hours";
    githubTokenFile = lib.mkOption {
      type = lib.types.str;
      example = "/run/secrets/github-update-token";
      description = "A file that holds a read-only GitHub token for this repository. Nix and gh use it, because GitHub's API limit for a client without a token is too low for an evaluation.";
    };
  };

  config = lib.mkIf cfg.enable {
    oruc.upgrade.updater = "oruc-auto-update";
    oruc.upgrade.skipLoadCheckFile = "/var/lib/oruc-auto-update/deploy-now";

    systemd.services.oruc-auto-update = lib.mkMerge [
      (import ./deploy-unit.nix { inherit config pkgs; } {
        name = "oruc-auto-update";
        script = ../scripts/pull-main.sh;
        user = config.oruc.machine.user;
        inherit (cfg) githubTokenFile;
        extraPath = [ pkgs.libnotify ];
      })
      {
        description = "Deploy the newest main";
        environment.HERDR_BIN = "/etc/profiles/per-user/${config.oruc.machine.user}/bin/herdr";
        unitConfig.ConditionACPower = true;
        onFailure = [ "oruc-auto-update-died.service" ];
      }
    ];

    systemd.services.oruc-auto-update-died = {
      description = "Desktop popup for a deploy run that ended without reporting";
      serviceConfig.Type = "oneshot";
      script = ''
        case ''${MONITOR_SERVICE_RESULT:-} in
          exit-code | timeout) exit 0 ;;
        esac
        ${pkgs.dbus}/bin/dbus-send --system / net.nuetzlich.SystemNotifications.Notify \
          "string:Update died" \
          "string:The run ended with ''${MONITOR_SERVICE_RESULT:-an unknown result} before it could report. See: journalctl -u ''${MONITOR_UNIT:-oruc-auto-update}"
      '';
    };

    systemd.timers.oruc-auto-update = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "0/2:00";
        Persistent = true;
        RandomizedDelaySec = "10min";
      };
    };
  };
}
