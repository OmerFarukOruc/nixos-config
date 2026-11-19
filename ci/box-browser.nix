flake:
builtins.mapAttrs
  (
    _: host:
    let
      inherit (host) config;
      browser = config.systemd.user.services.box-browser;
      grokBots = host.pkgs.lib.filterAttrs (
        name: _: host.pkgs.lib.hasPrefix "grok-bot-box-" name
      ) config.systemd.user.services;
      sessions = import ../machines/sessions.nix { inherit (host.pkgs) lib; };
    in
    {
      userUnits = builtins.attrNames config.systemd.user.services;
      displayCommand = config.systemd.user.services.box-display.serviceConfig.ExecStart;
      browserCommand = browser.serviceConfig.ExecStart;
      browserPreStart = toString browser.serviceConfig.ExecStartPre;
      browserEnvironment = browser.environment;
      browserTargets = browser.wantedBy;
      ownerLoopbackPorts = config.oruc.ownerLoopbackPorts;
      grokBotAccounts =
        if config.oruc.machine.features.grokBotBox then
          builtins.attrNames (import ../nixosModules/grok-bot-accounts.nix)
        else
          [ ];
      grokBots = builtins.mapAttrs (
        name: unit:
        let
          account = host.pkgs.lib.removePrefix "grok-bot-box-" name;
        in
        {
          command = unit.serviceConfig.ExecStart;
          inherit (unit) environment;
          displayCommand = config.systemd.user.services."grok-bot-display-${account}".serviceConfig.ExecStart;
          portFile = config.environment.etc."grok-bot-box/${account}.port".text;
        }
      ) grokBots;
      desktop = sessions.hasAnyDesktop config.oruc.machine;
      plasma = sessions.hasDesktop config.oruc.machine "plasma";
    }
  )
  {
    inherit (flake.nixosConfigurations) devbox nixos-rog nixos-desktop;
  }
