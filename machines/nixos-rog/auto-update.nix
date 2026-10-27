# Every 2 hours on AC power, scripts/pull-main.sh deploys the newest main to
# this host. .github/workflows/update.yml moves the inputs and apps and merges
# them to main. The token is a systemd credential, which the script writes to a
# private runtime Nix config for GitHub's API limit. The token stays out of
# child-process environments; the file remains readable by oruc.
#
# The unit's shared parts are in nixosModules/deploy-unit.nix, which a server's
# self-deploy (nixosModules/deploy-host.nix) uses too.
#
# The shared `upgrade` command (nixosModules/upgrade.nix) runs this unit now and
# shows its log while it runs.
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
      # notify-send of the script's popups.
      extraPath = [ pkgs.libnotify ];
    })
    {
      description = "Deploy the newest main";
      unitConfig.ConditionACPower = true;
      onFailure = [ "oruc-auto-update-died.service" ];
    }
  ];

  # The script's traps report a failed exit and the time limit. A run that ends
  # another way skips them, such as a kernel kill for memory (oom-kill, which
  # skips the TERM trap too) or a SIGKILL. This popup goes through
  # systembus-notify, which nixosModules/monitoring.nix turns on.
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
      # Every 2 hours.
      OnCalendar = "0/2:00";
      Persistent = true;
      RandomizedDelaySec = "10min";
    };
  };
}
