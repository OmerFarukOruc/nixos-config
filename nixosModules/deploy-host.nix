# What deploy.sh needs from the host it deploys, and how a server deploys
# itself (docs/deploy.md, Self-deploy of a server).
#
# - oruc.deploy.sessionIgnore lists the user services that deploy.sh's session
#   check leaves out. deploy.sh reads the list from the running system's
#   /etc/nixos-config-deploy/session-ignore.
# - oruc.deploy.self.enable runs scripts/self-deploy.sh from a timer as root,
#   and reboots at 02:10 UTC when the booted kernel or initrd is not the
#   running system's. It is not system.autoUpgrade, which skips deploy.sh's lock
#   and its rollback when sshd or tailscaled break. Root's home is where
#   deploy.sh keeps its lock and release records for a deploy over SSH too
#   (deployLogin in machines/schema.nix), so all of them share one set.
# - The unit is built by deploy-unit.nix, as nixos-rog's updater
#   (machines/nixos-rog/auto-update.nix) is. No option or upstream module runs
#   deploy.sh from a timer. oruc.deploy.self.githubTokenFile is the file that
#   holds the unit's GitHub token (docs/deploy.md, Limits).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.oruc.deploy;
  unit = "self-deploy";
in
{
  options.oruc.deploy = {
    sessionIgnore = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "herdr-*.service" ];
      description = "Shell globs of the user services that deploy.sh's session check ignores, such as long-running agents that a switch may restart.";
    };
    self.githubTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/github-update-token";
      description = "A file that holds a GitHub token. Nix and gh use it, because GitHub's API limit for a client without a token is too low for an evaluation.";
    };
    self.enable = lib.mkEnableOption "the timer that deploys the newest main to this host, and the reboot for a new kernel";
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.sessionIgnore != [ ]) {
      environment.etc."nixos-config-deploy/session-ignore".text = lib.concatLines cfg.sessionIgnore;
    })

    (lib.mkIf cfg.self.enable {
      # `upgrade` starts the unit instead of deploying as oruc, whose releases
      # and sudo password would differ from the unit's.
      oruc.upgrade.updater = unit;

      # A failed run writes its reason at priority err, which the telemetry
      # collector ships.
      oruc.telemetry.journalUnits = [
        "${unit}.service"
        "${unit}-reboot.service"
      ];

      systemd.services.${unit} =
        import ./deploy-unit.nix { inherit config pkgs; } {
          name = unit;
          script = ../scripts/self-deploy.sh;
          # deploy.sh keeps its state in the home of the user it runs as, which
          # systemd sets for a unit with User=.
          user = "root";
          githubTokenFile = cfg.self.githubTokenFile;
        }
        // {
          description = "Deploy the newest main to this host";
        };

      # Every 2 hours, as nixos-rog's deploy unit, so main reaches the host
      # within 2 hours and 10 minutes of a merge; the update workflow merges at
      # most every 6 hours. The even hours at :30 keep a run clear of the 02:10
      # reboot, and the timezone of common.nix does not move them.
      systemd.timers.${unit} = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-* 00/2:30:00 UTC";
          Persistent = true;
          RandomizedDelaySec = "10min";
        };
      };

      systemd.services."${unit}-reboot" = {
        description = "Reboot when the running kernel or initrd is not the booted one";
        # NixOS adds the system's systemd, which has shutdown.
        path = [ pkgs.util-linux ];
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          SyslogIdentifier = "${unit}-reboot";
          ExecStart = "${pkgs.bash}/bin/bash ${../scripts/self-deploy-reboot.sh}";
        };
      };

      # No Persistent, so a missed run does not reboot right after a boot.
      systemd.timers."${unit}-reboot" = {
        wantedBy = [ "timers.target" ];
        timerConfig.OnCalendar = "*-*-* 02:10:00 UTC";
      };
    })
  ];
}
