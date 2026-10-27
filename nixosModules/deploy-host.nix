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
# - The unit repeats the shared parts of machines/nixos-rog/auto-update.nix (the
#   path, the time limit, the restart rules). No option or upstream module runs
#   deploy.sh from a timer, so a change to those parts belongs in both files.
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
    self.repository = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/OmerFarukOruc/nixos-config.git";
      description = "The git repository that the host pulls main from.";
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

      systemd.services.${unit} = {
        description = "Deploy the newest main to this host";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        # The service runs the switch itself; restarting it then would kill
        # deploy.sh before it confirms the new system.
        restartIfChanged = false;
        # A rollback to a system without this unit must not stop it mid-deploy.
        unitConfig.X-StopOnRemoval = false;
        # NixOS adds coreutils, findutils, grep, sed and systemd to every
        # service. deploy.sh calls sudo, which lives in /run/wrappers/bin.
        path = [
          "/run/wrappers"
          config.nix.package
        ]
        ++ (with pkgs; [
          bash
          curl
          # deploy.sh's system diff.
          dix
          gawk
          git
          rsync
          # flock for deploy.sh's lock.
          util-linux
        ]);
        environment.SELF_DEPLOY_REPOSITORY = cfg.self.repository;
        serviceConfig = {
          Type = "oneshot";
          # deploy.sh keeps its state in the home of the user it runs as, which
          # systemd sets for a unit with User=.
          User = "root";
          # Without a limit one hung network call keeps the unit active, and
          # the timer never starts it again. The slowest deploy of 119 runs on
          # nixos-rog took 659 s (journal, 2026-10-16 to 2026-10-23); the rest
          # is room for compiling the packages that no cache holds. A kill
          # during deploy.sh leaves the rollback timer to restore the previous
          # system.
          TimeoutStartSec = "3h";
          # Slows the run above 12 GiB and never kills it, as on nixos-rog,
          # where the evaluation of every host peaked at 7.5 GiB (journal,
          # 2026-10-26). This unit evaluates one host.
          MemoryHigh = "12G";
          StateDirectory = unit;
          UMask = "0077";
          SyslogIdentifier = unit;
          ExecStart = "${pkgs.bash}/bin/bash ${../scripts/self-deploy.sh}";
        };
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
