{
  config,
  lib,
  pkgs,
  ...
}:
{
  oruc.upgrade.updater = "oruc-auto-update";

  sops.secrets.github-update-token = { };

  systemd.services.oruc-auto-update = lib.mkMerge [
    (import ../../nixosModules/deploy-unit.nix { inherit config pkgs; } {
      name = "oruc-auto-update";
      script = ../../scripts/pull-main.sh;
      user = "oruc";
      githubTokenFile = config.sops.secrets.github-update-token.path;
      extraPath = [ pkgs.libnotify ];
    })
    {
      description = "Deploy the newest main";
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
}
