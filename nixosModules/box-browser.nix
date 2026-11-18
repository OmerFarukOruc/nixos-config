{
  config,
  lib,
  pkgs,
  sessions,
  ...
}:
let
  machine = config.oruc.machine;
  desktop = sessions.hasAnyDesktop machine;
  passwordStore = if sessions.hasDesktop machine "plasma" then "kwallet6" else "basic";
  sessionTarget = if desktop then "graphical-session.target" else "default.target";
  sessionEdges = lib.optional desktop sessionTarget;
  displayNumber = 20;
  display = ":${toString displayNumber}";
  vncPort = 5920;
  cdpPort = 9344;

  # Xvnc sends no readiness signal, so the browser waits for its socket. A
  # Chromium that died hard leaves Singleton* files, and a reused process id
  # makes the next start refuse the profile as in use.
  browserPrepare = pkgs.writeShellApplication {
    name = "box-browser-prepare";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      profile="$HOME/.local/share/box-browser/profile"
      mkdir -p "$profile"
      rm -f "$profile/SingletonLock" "$profile/SingletonCookie" "$profile/SingletonSocket"
      for _ in {1..30}; do
        [[ -S /tmp/.X11-unix/X${toString displayNumber} ]] && exit 0
        sleep 1
      done
      echo "The X socket of display ${display} did not appear." >&2
      exit 1
    '';
  };

  displayPrepare = pkgs.writeShellApplication {
    name = "box-display-prepare";
    runtimeInputs = [
      pkgs.util-linux
      pkgs.xauth
    ];
    text = ''
      touch "$HOME/.Xauthority"
      xauth -f "$HOME/.Xauthority" remove ${display}
      xauth -f "$HOME/.Xauthority" add ${display} . "$(mcookie)"
    '';
  };

  # Chromium falls back to its fixed key when KWallet is closed
  # (chromium docs/linux/password_storage.md), so the browser starts only once
  # the wallet is open; on nixos-desktop that is Omer's first unlock after boot.
  walletOpen = pkgs.writeShellApplication {
    name = "box-browser-wallet-open";
    runtimeInputs = [
      pkgs.jq
      pkgs.systemd
    ];
    text = ''
      kwallet() { busctl --user --json=short call org.kde.kwalletd6 /modules/kwalletd6 org.kde.KWallet "$@" 2> /dev/null | jq -r '.data[0]'; }
      until wallet=$(kwallet localWallet) && [[ $(kwallet isOpen s "$wallet") == true ]]; do
        sleep 5
      done
    '';
  };

in
{
  config = lib.mkIf machine.features.boxBrowser {
    users.users.${machine.user}.linger = lib.mkIf (!desktop) true;

    # The ruleset check runs in the build sandbox, which has no such user.
    networking.nftables.preCheckRuleset = lib.mkIf config.networking.nftables.enable ''
      sed -i 's/"${machine.user}"/"nobody"/' ruleset.conf
    '';
    networking.nftables.tables.box-browser = lib.mkIf config.networking.nftables.enable {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy accept;
          oifname "lo" tcp dport { ${toString vncPort}, ${toString cdpPort} } meta skuid != { 0, "${machine.user}" } reject
        }
      '';
    };

    fonts.enableDefaultPackages = lib.mkDefault true;

    environment.etc."chromium/policies/managed/box-browser.json" = lib.mkIf (passwordStore == "basic") {
      text = builtins.toJSON { PasswordManagerEnabled = false; };
    };

    systemd.user.services.box-display = {
      description = "Box browser display: Xvnc ${display}, localhost only, no VNC password, X cookie in ~/.Xauthority";
      wantedBy = [ sessionTarget ];
      partOf = sessionEdges;
      after = sessionEdges;
      unitConfig = {
        ConditionUser = machine.user;
        StartLimitIntervalSec = 0;
      };
      serviceConfig = {
        ExecStartPre = lib.getExe displayPrepare;
        ExecStart = lib.concatStringsSep " " [
          (lib.getExe' pkgs.tigervnc "Xvnc")
          display
          "-auth %h/.Xauthority"
          "-localhost"
          "-rfbport ${toString vncPort}"
          "-nolisten tcp"
          "-SecurityTypes None"
          "-desktop box-browser"
          "-geometry 1920x1080"
          "-depth 24"
          "-AlwaysShared"
        ];
        Restart = "always";
        RestartSec = 2;
      };
    };

    systemd.user.services.box-browser = {
      description = "Box browser: Chromium on ${display}, DevTools on 127.0.0.1:${toString cdpPort}";
      requires = [ "box-display.service" ];
      after = [
        "box-display.service"
      ]
      ++ sessionEdges
      ++ lib.optionals (passwordStore == "kwallet6") [
        "kwallet-pam.service"
        "plasma-kwallet-pam.service"
      ];
      partOf = [ "box-display.service" ] ++ sessionEdges;
      wantedBy = [ sessionTarget ];
      environment = {
        DISPLAY = display;
        XAUTHORITY = "%h/.Xauthority";
      };
      unitConfig = {
        ConditionUser = machine.user;
        StartLimitIntervalSec = 0;
      };
      serviceConfig = {
        ExecStartPre = lib.optional (passwordStore == "kwallet6") (lib.getExe walletOpen) ++ [
          (lib.getExe browserPrepare)
        ];
        TimeoutStartSec = lib.mkIf (passwordStore == "kwallet6") "infinity";
        ExecStart = lib.concatStringsSep " " [
          (lib.getExe pkgs.chromium)
          "--user-data-dir=%h/.local/share/box-browser/profile"
          "--remote-debugging-address=127.0.0.1"
          "--remote-debugging-port=${toString cdpPort}"
          "--ozone-platform=x11"
          "--password-store=${passwordStore}"
          "--no-first-run"
          "--no-default-browser-check"
          "--window-position=0,0"
          "--window-size=1920,1080"
        ];
        Restart = "always";
        RestartSec = 2;
      };
    };
  };
}
