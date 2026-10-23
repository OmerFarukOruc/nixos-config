# Every hour on AC power, scripts/auto-update.sh moves the flake inputs and the
# apps in pkgs/ that name a release source to their newest releases, deploys
# them to this host and merges them to main. The token is a systemd credential,
# and the script writes private runtime config files for gh and Nix. The token
# stays out of child-process environments; files remain readable by oruc.
#
# The shared `upgrade` command (nixosModules/upgrade.nix) runs the updater now
# and shows its log while it runs; `upgrade --rehearse` runs the rehearsal unit
# below.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  updater = {
    description = "Update, deploy and merge the newest releases";
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
      # The system diff in the PR body.
      dix
      gawk
      gh
      git
      jq
      libnotify
      python3
      rsync
      # flock for deploy.sh's lock.
      util-linux
    ]);
    serviceConfig = {
      Type = "oneshot";
      # Without a limit one hung network call keeps the unit active, and the
      # timer never starts it again. The longest run in the journal (24 runs
      # from 2026-10-10 to 2026-10-12) took 3 min 13 s, and the checks before
      # the deploy took 70 s (local_checks alone on a warm store, 2026-10-21).
      # The rest is room for compiling the packages of ci/cached-packages.nix
      # when no cache holds them, for up to 30 minutes of waiting for the
      # build lock, and for the new rounds that the script starts within 20
      # minutes when main moves. A kill sends the script SIGTERM, and its trap
      # notifies. A kill during deploy.sh leaves the rollback timer to restore
      # the previous system.
      TimeoutStartSec = "3h";
      # Slows the run above 10 GiB, as heavy does, and never kills it, so the
      # script's traps still report. A MemoryMax kill would skip them. The
      # highest peak of 65 runs from 2026-10-14 to 2026-10-17 was 7.4G
      # (journal).
      MemoryHigh = "10G";
      User = "oruc";
      StateDirectory = "oruc-auto-update";
      RuntimeDirectory = "oruc-auto-update";
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
      SyslogIdentifier = "oruc-auto-update";
      LoadCredential = [
        "github-token:${config.sops.secrets.github-update-token.path}"
      ];
      ExecStart = "${pkgs.bash}/bin/bash ${../../scripts/auto-update.sh}";
    };
    onFailure = [ "oruc-auto-update-died.service" ];
  };

in
{
  oruc.upgrade.updater = "oruc-auto-update";

  sops.secrets.github-update-token = { };

  systemd.services.oruc-auto-update = updater;
  # `upgrade --rehearse`: the same run from an older flake.lock, which builds
  # instead of deploying and merges into a throwaway branch
  # (scripts/auto-update.sh). Its own state, so it never marks a real
  # candidate as failed.
  systemd.services.oruc-auto-update-rehearsal = lib.recursiveUpdate updater {
    description = "Rehearse an update without activating it";
    environment.AUTO_UPDATE_REHEARSAL = "1";
    serviceConfig = {
      StateDirectory = "oruc-auto-update-rehearsal";
      RuntimeDirectory = "oruc-auto-update-rehearsal";
      SyslogIdentifier = "oruc-auto-update-rehearsal";
    };
  };

  # The script's traps report a failed exit and the time limit. A run that ends
  # another way skips them, such as a kernel kill for memory (oom-kill, which
  # skips the TERM trap too) or a SIGKILL. This popup goes through
  # systembus-notify, which machines/nixos-rog/monitoring.nix turns on.
  systemd.services.oruc-auto-update-died = {
    description = "Desktop popup for an updater run that ended without reporting";
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
      OnCalendar = "hourly";
      Persistent = true;
      RandomizedDelaySec = "10min";
    };
  };
}
