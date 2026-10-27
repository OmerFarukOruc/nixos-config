# Every 2 hours on AC power, scripts/pull-main.sh deploys the newest main to
# this host. .github/workflows/update.yml moves the inputs and apps and merges
# them to main. The token is a systemd credential, which the script writes to a
# private runtime Nix config for GitHub's API limit. The token stays out of
# child-process environments; the file remains readable by oruc.
#
# The server copy of this unit is nixosModules/deploy-host.nix; change both.
#
# The shared `upgrade` command (nixosModules/upgrade.nix) runs this unit now and
# shows its log while it runs.
{
  config,
  pkgs,
  ...
}:
let
  updater = {
    description = "Deploy the newest main";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    # The service runs the switch itself; restarting it then would kill
    # deploy.sh before it confirms the new system.
    restartIfChanged = false;
    unitConfig = {
      # A rollback to a system without this unit must not stop it mid-deploy.
      X-StopOnRemoval = false;
      ConditionACPower = true;
    };
    # NixOS adds coreutils, findutils, grep, sed and systemd to every service.
    # deploy.sh calls sudo, which lives in /run/wrappers/bin.
    path = [
      "/run/wrappers"
      config.nix.package
    ]
    ++ (with pkgs; [
      bash
      curl
      diffutils
      # deploy.sh's system diff.
      dix
      gawk
      gh
      git
      jq
      libnotify
      rsync
      # flock for deploy.sh's lock.
      util-linux
    ]);
    serviceConfig = {
      Type = "oneshot";
      # Without a limit one hung network call keeps the unit active, and the
      # timer never starts it again. The slowest deploy of 119 runs of the old updater
      # took 659 s (journal, 2026-10-16 to 2026-10-23); the rest is room for
      # compiling the packages that no cache holds. A kill sends the script
      # SIGTERM, and its trap notifies. A kill during deploy.sh leaves the
      # rollback timer to restore the previous system.
      TimeoutStartSec = "3h";
      # Slows the run above 12 GiB and never kills it, so the script's traps
      # still report. A MemoryMax kill would skip them. The old updater, which
      # also evaluated every host, peaked at 7.5 GiB (journal, 2026-10-26).
      MemoryHigh = "12G";
      User = "oruc";
      StateDirectory = "oruc-auto-update";
      RuntimeDirectory = "oruc-auto-update";
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
      SyslogIdentifier = "oruc-auto-update";
      LoadCredential = [
        "github-token:${config.sops.secrets.github-update-token.path}"
      ];
      ExecStart = "${pkgs.bash}/bin/bash ${../../scripts/pull-main.sh}";
    };
    onFailure = [ "oruc-auto-update-died.service" ];
  };

in
{
  oruc.upgrade.updater = "oruc-auto-update";

  sops.secrets.github-update-token = { };

  systemd.services.oruc-auto-update = updater;

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
