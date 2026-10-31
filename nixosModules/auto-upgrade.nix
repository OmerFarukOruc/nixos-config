{
  config,
  lib,
  pkgs,
  sessions,
  ...
}:
let
  cfg = config.oruc.autoUpgrade;
  deployUser = lib.defaultTo config.oruc.machine.user config.oruc.machine.deployLogin;
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
  options.oruc.autoUpgrade = {
    enable = lib.mkEnableOption "the hourly install of the newest main with system.autoUpgrade";
    reboot = lib.mkEnableOption "a night reboot when the new main changes the kernel, the initrd or the kernel modules (docs/deploy.md, Deploy to a server)";
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.reboot || config.time.timeZone == "Europe/Istanbul";
        message = "oruc.autoUpgrade.reboot sets a rebootWindow in Europe/Istanbul time; change the window with the time zone.";
      }
    ];

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
      allowReboot = cfg.reboot;
      rebootWindow = lib.mkIf cfg.reboot {
        lower = "03:00";
        upper = "07:00";
      };
    };

    oruc.telemetry.journalUnits = [ "nixos-upgrade.service" ];

    systemd.services.nixos-upgrade = {
      unitConfig.ConditionACPower = true;
      onFailure = [ "nixos-upgrade-failed.service" ];
      environment = {
        REPOSITORY = "https://github.com/OmerFarukOruc/nixos-config.git";
        DEPLOY_HOME = config.users.users.${deployUser}.home;
        RUNNING_REVISION_LIB = "${../scripts/lib/running-revision.sh}";
      };
      serviceConfig = {
        StateDirectory = "nixos-upgrade";
        SyslogIdentifier = "nixos-upgrade";
        TimeoutStartSec = "3h";
        MemoryHigh = "12G";
        ExecCondition = lib.getExe condition;
        ExecStartPost = pkgs.writeShellScript "nixos-upgrade-installed" ''
          running=$(${pkgs.coreutils}/bin/readlink -f /run/current-system)
          if [[ $running == "$(${pkgs.coreutils}/bin/readlink -f /nix/var/nix/profiles/system)" ]]; then
            printf 'system=%s\nrevision=%s\n' "$running" "$(<${state}/candidate)" >${state}/installed
          fi
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
