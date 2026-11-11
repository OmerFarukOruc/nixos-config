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
  report = pkgs.writeShellApplication {
    name = "install-report";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      gh
      gh-token
      gitleaks
      gitMinimal
      gnugrep
      gnused
      config.nix.package
      config.systemd.package
    ];
    text = builtins.readFile ../scripts/install-report.sh;
  };
  runReport = mode: ''
    ${pkgs.coreutils}/bin/timeout 120 ${lib.getExe report} ${mode} || echo "install-report: no answer from GitHub within 120 s"
  '';
  reportEnvironment = {
    HOST = config.networking.hostName;
    SSH_LOGIN = "${config.oruc.machine.user}@${config.networking.hostName}";
    REBOOTS = lib.boolToString cfg.reboot;
    APP_ID_FILE = config.sops.secrets.install-reports-app-id.path;
    KEY_FILE = config.sops.secrets.install-reports-key.path;
    VALUES_FILE = config.sops.secrets.agents-private-values.path;
    GH_CONFIG_DIR = "${state}/gh";
  };
in
{
  options.oruc.autoUpgrade = {
    enable = lib.mkEnableOption "the hourly install of the newest main with system.autoUpgrade";
    reboot = lib.mkEnableOption "a night reboot when the new main changes the kernel, the initrd or the kernel modules (docs/deploy.md, Deploy to a server)";
    issueReports = lib.mkEnableOption "a GitHub issue for each failed install, posted as the GitHub App nixos-config-hosts (docs/workstations.md, Failures and notifications); nixosModules/install-reports.nix sets it with the App's secrets";
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

    systemd.services.nixos-upgrade = {
      unitConfig.ConditionACPower = true;
      onFailure = [ "nixos-upgrade-failed.service" ];
      environment = {
        REPOSITORY = "https://github.com/OmerFarukOruc/nixos-config.git";
        DEPLOY_HOME = config.users.users.${deployUser}.home;
        RUNNING_REVISION_LIB = "${../scripts/lib/running-revision.sh}";
      }
      // lib.optionalAttrs cfg.issueReports reportEnvironment;
      serviceConfig = {
        StateDirectory = "nixos-upgrade";
        SyslogIdentifier = "nixos-upgrade";
        TimeoutStartSec = "3h";
        MemoryHigh = "12G";
        ExecCondition = lib.getExe condition;
        ExecStartPost = pkgs.writeShellScript "nixos-upgrade-installed" (
          ''
            running=$(${pkgs.coreutils}/bin/readlink -f /run/current-system)
            if [[ $running == "$(${pkgs.coreutils}/bin/readlink -f /nix/var/nix/profiles/system)" ]]; then
              printf 'system=%s\nrevision=%s\n' "$running" "$(<${state}/candidate)" >${state}/installed
          ''
          + lib.optionalString cfg.issueReports (runReport "installed")
          + ''
            fi
            ${pkgs.coreutils}/bin/rm -f ${state}/failed
          ''
        );
      };
    };

    systemd.services.nixos-upgrade-failed = {
      description = "Record a failed install of main and report it";
      serviceConfig.Type = "oneshot";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = lib.optionalAttrs cfg.issueReports reportEnvironment;
      script = ''
        if [[ ''${MONITOR_SERVICE_RESULT:-} == signal ]]; then
          echo "nixos-upgrade was stopped by a signal, so main is not recorded as failed"
          exit 0
        fi
        if [[ -f ${state}/candidate ]]; then
          cp ${state}/candidate ${state}/failed
        fi
      ''
      + lib.optionalString (sessions.hasAnyDesktop config.oruc.machine) ''
        ${pkgs.dbus}/bin/dbus-send --system / net.nuetzlich.SystemNotifications.Notify \
          "string:Update failed" \
          "string:${config.networking.hostName} could not install main at $(cut -c1-12 ${state}/candidate) and keeps its system until main moves. See: journalctl -u nixos-upgrade" \
          || echo "The Update failed popup could not be sent"
      ''
      + lib.optionalString cfg.issueReports (runReport "failed");
    };
  };
}
