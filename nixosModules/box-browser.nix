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
  vncPort = 5920;
  cdpPort = 9344;

  boxDisplay = import ./vnc-display.nix { inherit lib pkgs; } {
    number = 20;
    inherit vncPort;
    desktopName = "box-browser";
    description = "Box browser display: Xvnc :20, localhost only, no VNC password, X cookie in ~/.Xauthority";
    inherit (machine) user;
    wantedBy = [ sessionTarget ];
    inherit sessionEdges;
  };
  inherit (boxDisplay) display;

  # A Chromium that died hard leaves Singleton* files, and a reused process id
  # makes the next start refuse the profile as in use.
  browserPrepare = pkgs.writeShellApplication {
    name = "box-browser-prepare";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      profile="$HOME/.local/share/box-browser/profile"
      mkdir -p "$profile"
      rm -f "$profile/SingletonLock" "$profile/SingletonCookie" "$profile/SingletonSocket"
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
      until wallet=$(kwallet networkWallet) && [[ $(kwallet isOpen s "$wallet") == true ]]; do
        sleep 5
      done
    '';
  };

in
{
  config = lib.mkIf machine.features.boxBrowser {
    users.users.${machine.user}.linger = lib.mkIf (!desktop) true;

    systemd.services.browser-lend-off = lib.mkIf (desktop && config.services.tailscale.enable) {
      description = "Remove tailscale serve listeners on tailnet ports 9222 and 9223";
      after = [ "tailscaled.service" ];
      wants = [ "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [
        config.services.tailscale.package
        pkgs.jq
      ];
      serviceConfig.Type = "oneshot";
      script = ''
        serve=$(tailscale serve status --json)
        if jq -e '.TCP["9222"]' <<< "$serve" > /dev/null; then tailscale serve --tcp=9222 off; fi
        if jq -e '.TCP["9223"]' <<< "$serve" > /dev/null; then tailscale serve --https=9223 off; fi
        tailscale serve status --json | jq -e '.TCP // {} | has("9222") or has("9223") | not' > /dev/null
      '';
    };

    oruc.ownerLoopbackPorts = [
      vncPort
      cdpPort
    ];

    fonts.enableDefaultPackages = lib.mkDefault true;

    systemd.user.services.box-display = boxDisplay.service;

    systemd.user.services.box-browser = {
      description = "Box browser: Chromium on ${display}, DevTools on 127.0.0.1:${toString cdpPort}";
      requires = [ "box-display.service" ];
      after = [
        "box-display.service"
      ]
      ++ sessionEdges;
      partOf = [ "box-display.service" ] ++ sessionEdges;
      wantedBy = [ sessionTarget ];
      inherit (boxDisplay) environment;
      unitConfig = {
        ConditionUser = machine.user;
        StartLimitIntervalSec = 0;
      };
      serviceConfig = {
        ExecStartPre = lib.optional (passwordStore == "kwallet6") (lib.getExe walletOpen) ++ [
          (lib.getExe browserPrepare)
          boxDisplay.waitCommand
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
