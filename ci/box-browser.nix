flake:
builtins.mapAttrs
  (
    _: host:
    let
      inherit (host) config;
      browser = config.systemd.user.services.box-browser;
      sessions = import ../machines/sessions.nix { inherit (host.pkgs) lib; };
    in
    {
      userUnits = builtins.attrNames config.systemd.user.services;
      displayCommand = config.systemd.user.services.box-display.serviceConfig.ExecStart;
      browserCommand = browser.serviceConfig.ExecStart;
      browserPreStart = toString browser.serviceConfig.ExecStartPre;
      browserEnvironment = browser.environment;
      browserTargets = browser.wantedBy;
      desktop = sessions.hasAnyDesktop config.oruc.machine;
      plasma = sessions.hasDesktop config.oruc.machine "plasma";
    }
  )
  {
    inherit (flake.nixosConfigurations) devbox nixos-rog nixos-desktop;
  }
