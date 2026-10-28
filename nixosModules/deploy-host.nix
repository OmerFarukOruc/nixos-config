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
      oruc.upgrade.updater = unit;

      oruc.telemetry.journalUnits = [
        "${unit}.service"
        "${unit}-reboot.service"
      ];

      systemd.services.${unit} =
        import ./deploy-unit.nix { inherit config pkgs; } {
          name = unit;
          script = ../scripts/self-deploy.sh;
          user = "root";
          githubTokenFile = cfg.self.githubTokenFile;
        }
        // {
          description = "Deploy the newest main to this host";
        };

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
        path = [ pkgs.util-linux ];
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          SyslogIdentifier = "${unit}-reboot";
          ExecStart = "${pkgs.bash}/bin/bash ${../scripts/self-deploy-reboot.sh}";
        };
      };

      systemd.timers."${unit}-reboot" = {
        wantedBy = [ "timers.target" ];
        timerConfig.OnCalendar = "*-*-* 02:10:00 UTC";
      };
    })
  ];
}
