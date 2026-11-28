{
  config,
  lib,
  pkgs,
  sessions,
  ...
}:
let
  cfg = config.oruc.autoUpgrade;
  inherit (config.oruc.machine) deployUser;
  state = "/var/lib/nixos-upgrade";
  rebootWindow = {
    lower = "03:00";
    upper = "07:00";
  };
  condition = pkgs.writeShellApplication {
    name = "nixos-upgrade-condition";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      gitMinimal
      gnugrep
      gnused
      jq
      procps
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
  failed = pkgs.writeShellApplication {
    name = "nixos-upgrade-failed";
    runtimeInputs = with pkgs; [
      coreutils
      dbus
    ];
    text = builtins.readFile ../scripts/upgrade-failed.sh;
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
    issueReports = lib.mkEnableOption "a GitHub issue for each revision of main that fails to install twice, posted as the GitHub App nixos-config-hosts (docs/workstations.md, Failures and notifications); nixosModules/install-reports.nix sets it with the App's secrets";
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
      rebootWindow = lib.mkIf cfg.reboot rebootWindow;
    };

    systemd.services.nixos-upgrade = {
      unitConfig.ConditionACPower = true;
      onFailure = [ "nixos-upgrade-failed.service" ];
      environment = {
        REPOSITORY = "https://github.com/OmerFarukOruc/nixos-config.git";
        DEPLOY_HOME = config.users.users.${deployUser}.home;
        RUNNING_REVISION_LIB = "${../scripts/lib/running-revision.sh}";
      }
      // lib.optionalAttrs cfg.reboot {
        REBOOT_WINDOW_LOWER = rebootWindow.lower;
        REBOOT_WINDOW_UPPER = rebootWindow.upper;
        AGENTS_USER = config.oruc.machine.user;
        AGENTS_HOME = config.users.users.${config.oruc.machine.user}.home;
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
            ${pkgs.coreutils}/bin/rm -f ${state}/failed ${state}/retry
          ''
        );
      };
    };

    systemd.services.nixos-upgrade-failed = {
      description = "Record a failed install of main and report it";
      serviceConfig.Type = "oneshot";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment =
        lib.optionalAttrs cfg.issueReports (reportEnvironment // { INSTALL_REPORT = lib.getExe report; })
        // lib.optionalAttrs (sessions.hasAnyDesktop config.oruc.machine) {
          POPUP_HOST = config.networking.hostName;
        };
      script = lib.getExe failed;
    };
  };
}
