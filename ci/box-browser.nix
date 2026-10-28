flake:
let
  system = flake.nixosConfigurations.nixos-desktop.extendModules {
    modules = [
      (
        { lib, ... }:
        {
          oruc.machine.features.boxBrowser = lib.mkForce true;
        }
      )
    ];
  };
in
{
  drvPath = system.config.system.build.toplevel.drvPath;
  userUnits = builtins.attrNames system.config.systemd.user.services;
  displayCommand = system.config.systemd.user.services.box-display.serviceConfig.ExecStart;
}
