# Every hour on AC power, scripts/auto-update.sh moves the flake inputs and the
# apps in pkgs/ that name a release source to their newest releases, deploys
# them to this host and merges them to main. The token is a systemd credential,
# but the script exports it as GH_TOKEN and in NIX_CONFIG, so while a run lasts
# any process of oruc can read it from /proc/<pid>/environ.
{ config, pkgs, ... }:
{
  sops.secrets.github-update-token = { };

  systemd.services.oruc-auto-update = {
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
      # from 2026-10-10 to 2026-10-12) took 3 min 13 s; the rest is room for
      # compiling the packages of ci/cached-packages.nix when no cache holds
      # them. A kill sends the script SIGTERM, and its trap notifies. A kill
      # during deploy.sh leaves the rollback timer to restore the previous
      # system.
      TimeoutStartSec = "2h";
      User = "oruc";
      StateDirectory = "oruc-auto-update";
      LoadCredential = "github-token:${config.sops.secrets.github-update-token.path}";
      ExecStart = "${pkgs.bash}/bin/bash ${../../scripts/auto-update.sh}";
    };
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
