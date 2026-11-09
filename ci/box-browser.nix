flake:
let
  inherit (flake.nixosConfigurations.nixos-desktop) config;
in
{
  userUnits = builtins.attrNames config.systemd.user.services;
  displayCommand = config.systemd.user.services.box-display.serviceConfig.ExecStart;
  browserEnvironment = config.systemd.user.services.box-browser.environment;
}
