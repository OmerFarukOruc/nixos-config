flake:
builtins.mapAttrs
  (
    _: host:
    let
      inherit (host) config;
    in
    {
      userUnits = builtins.attrNames config.systemd.user.services;
      displayCommand = config.systemd.user.services.box-display.serviceConfig.ExecStart;
      browserCommand = config.systemd.user.services.box-browser.serviceConfig.ExecStart;
      browserEnvironment = config.systemd.user.services.box-browser.environment;
      passwordPolicy = config.environment.etc ? "chromium/policies/managed/box-browser.json";
    }
  )
  {
    inherit (flake.nixosConfigurations) devbox nixos-rog nixos-desktop;
  }
