{
  config,
  lib,
  pkgs,
  sessions,
  ...
}:
let
  cfg = config.oruc.autoUpgrade;
  state = "/var/lib/nixos-upgrade";
  condition = pkgs.writeShellApplication {
    name = "nixos-upgrade-condition";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      gitMinimal
      gnugrep
      gnused
      util-linux
      config.systemd.package
    ];
    text = builtins.readFile ../scripts/upgrade-condition.sh;
  };
in
{
  options.oruc.autoUpgrade.enable = lib.mkEnableOption "the hourly install of the newest main with system.autoUpgrade";

  config = lib.mkIf cfg.enable {
    oruc.upgrade = {
      updater = "nixos-upgrade";
      nowFile = "${state}/now";
    };

    systemd.tmpfiles.rules = [ "d ${state} 0755 root root -" ];

    system.autoUpgrade = {
      enable = true;
      flake = "git+file://${state}/repo.git";
      upgrade = false;
      dates = "hourly";
      randomizedDelaySec = "10min";
      persistent = true;
    };

    systemd.services.nixos-upgrade = {
      unitConfig.ConditionACPower = true;
      onFailure = [ "nixos-upgrade-failed.service" ];
      environment = {
        REPOSITORY = "https://github.com/OmerFarukOruc/nixos-config.git";
        DEPLOY_HOME = config.users.users.${config.oruc.machine.user}.home;
        RUNNING_REVISION_LIB = "${../scripts/lib/running-revision.sh}";
      };
      serviceConfig = {
        StateDirectory = "nixos-upgrade";
        TimeoutStartSec = "3h";
        MemoryHigh = "12G";
        ExecCondition = lib.getExe condition;
        ExecStartPost = pkgs.writeShellScript "nixos-upgrade-installed" ''
          printf 'system=%s\nrevision=%s\n' "$(${pkgs.coreutils}/bin/readlink -f /run/current-system)" \
            "$(<${state}/candidate)" >${state}/installed
          ${pkgs.coreutils}/bin/rm -f ${state}/failed
        '';
      };
    };

    systemd.services.nixos-upgrade-failed = {
      description = "Record a failed install of main and report it";
      serviceConfig.Type = "oneshot";
      script = ''
        if [[ -f ${state}/candidate ]]; then
          cp ${state}/candidate ${state}/failed
        fi
      ''
      + lib.optionalString (sessions.hasAnyDesktop config.oruc.machine) ''
        ${pkgs.dbus}/bin/dbus-send --system / net.nuetzlich.SystemNotifications.Notify \
          "string:Update failed" \
          "string:${config.networking.hostName} could not install main at $(cut -c1-12 ${state}/candidate) and keeps its system until main moves. See: journalctl -u nixos-upgrade"
      '';
    };
  };
}
