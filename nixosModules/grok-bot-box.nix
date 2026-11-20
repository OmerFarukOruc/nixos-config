{
  config,
  lib,
  pkgs,
  sessions,
  ...
}:
let
  inherit (config.oruc) machine;
  grokBot = pkgs.callPackage ../pkgs/grok-bot.nix { };
  accounts = import ./grok-bot-accounts.nix;
  vncDisplay = import ./vnc-display.nix { inherit lib pkgs; };

  # Electron leaves Singleton* files when it dies hard, and a reused process id
  # makes the next start exit as a second instance.
  prepare = pkgs.writeShellApplication {
    name = "grok-bot-box-prepare";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      profile="$XDG_CONFIG_HOME/Grok Bot"
      mkdir -p "$profile"
      chmod 700 "$XDG_CONFIG_HOME"
      rm -f "$profile/SingletonLock" "$profile/SingletonCookie" "$profile/SingletonSocket"
    '';
  };

  idleMinutes = 30;
  idle = pkgs.writeShellApplication {
    name = "grok-bot-box-idle";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.iproute2
      pkgs.systemd
    ];
    text = ''
      usage() {
        echo "usage: grok-bot-box-idle used ACCOUNT | check ACCOUNT VNC_PORT DEVTOOLS_PORT" >&2
        exit 2
      }
      (($# >= 2)) || usage
      used="$XDG_RUNTIME_DIR/grok-bot-box/$2.used"
      mkdir -p "$(dirname "$used")"
      case $1 in
        used) touch "$used" ;;
        check)
          (($# == 4)) || usage
          connections=$(ss -Htn state established "( sport = :$3 or sport = :$4 )")
          if [[ -n $connections || ! -e $used ]]; then
            touch "$used"
          elif (($(date +%s) - $(stat -c %Y "$used") >= ${toString (idleMinutes * 60)})); then
            rm -f "$used"
            systemctl --user stop --no-block "grok-bot-display-$2.service"
          fi
          ;;
        *) usage ;;
      esac
    '';
  };

  # Without a window manager the app's window stays 512x520.
  windowManagerConfig = pkgs.writeText "grok-bot-box-ratpoisonrc" ''
    set startupmessage 0
    set border 0
    escape C-F12
  '';

  units =
    account:
    {
      display,
      vncPort,
      cdpPort,
    }:
    let
      screen = vncDisplay {
        number = display;
        inherit vncPort;
        desktopName = "grok-bot-${account}";
        description = "Grok Bot display, ${account} account: Xvnc :${toString display}, localhost only, no VNC password";
        inherit (machine) user;
        wantedBy = [ ];
        sessionEdges = [ ];
      };
      displayUnit = "grok-bot-display-${account}.service";
      windowManagerUnit = "grok-bot-wm-${account}.service";
      onDisplay = {
        requires = [ displayUnit ];
        after = [ displayUnit ];
        partOf = [ displayUnit ];
        unitConfig = {
          ConditionUser = machine.user;
          StartLimitIntervalSec = 0;
        };
      };
    in
    {
      "grok-bot-display-${account}" = screen.service;
      "grok-bot-wm-${account}" = onDisplay // {
        description = "Grok Bot window manager, ${account} account: ratpoison on ${screen.display}";
        inherit (screen) environment;
        serviceConfig = {
          ExecStartPre = screen.waitCommand;
          ExecStart = "${lib.getExe pkgs.ratpoison} -f ${windowManagerConfig}";
          Restart = "always";
          RestartSec = 2;
        };
      };
      "grok-bot-box-${account}" = onDisplay // {
        description = "Grok Bot, ${account} account: on ${screen.display}, DevTools on 127.0.0.1:${toString cdpPort}";
        wants = [
          windowManagerUnit
          "grok-bot-idle-${account}.timer"
        ];
        after = [
          displayUnit
          windowManagerUnit
        ];
        # The app ignores --user-data-dir and keeps its profile and its
        # single-instance lock in $XDG_CONFIG_HOME/Grok Bot.
        environment = screen.environment // {
          XDG_CONFIG_HOME = "%h/.local/share/grok-bot-box/${account}";
        };
        serviceConfig = {
          ExecStartPre = [
            (lib.getExe prepare)
            screen.waitCommand
          ];
          ExecStart = lib.concatStringsSep " " [
            (lib.getExe grokBot)
            "--remote-debugging-address=127.0.0.1"
            "--remote-debugging-port=${toString cdpPort}"
            "--ozone-platform=x11"
            "--password-store=basic"
          ];
          # The app dumps core on SIGTERM and exits 0 on SIGINT.
          KillSignal = "SIGINT";
          Restart = "always";
          RestartSec = 2;
        };
      };
      "grok-bot-idle-${account}" = {
        description = "Grok Bot, ${account} account: stop it after ${toString idleMinutes} minutes with no connection to its VNC or DevTools port";
        unitConfig.ConditionUser = machine.user;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${lib.getExe idle} check ${account} ${toString vncPort} ${toString cdpPort}";
        };
      };
    };
in
{
  config = lib.mkIf machine.features.grokBotBox {
    users.users.${machine.user}.linger = lib.mkIf (!sessions.hasAnyDesktop machine) true;

    oruc.ownerLoopbackPorts = lib.concatMap (account: [
      account.vncPort
      account.cdpPort
    ]) (lib.attrValues accounts);

    environment.systemPackages = [ idle ];

    environment.etc = lib.mapAttrs' (
      account: ports:
      lib.nameValuePair "grok-bot-box/${account}.port" { text = "${toString ports.cdpPort}\n"; }
    ) accounts;

    systemd.user.services = lib.concatMapAttrs units accounts;

    systemd.user.timers = lib.mapAttrs' (
      account: _:
      lib.nameValuePair "grok-bot-idle-${account}" {
        description = "Grok Bot, ${account} account: check every 5 minutes whether it is still in use";
        partOf = [ "grok-bot-display-${account}.service" ];
        timerConfig = {
          OnActiveSec = "5min";
          OnUnitActiveSec = "5min";
        };
      }
    ) accounts;
  };
}
