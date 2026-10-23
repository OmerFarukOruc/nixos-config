# nixos-desktop with features.boxBrowser forced on. No host turns the feature
# on, so no other check evaluates nixosModules/box-browser.nix. Forcing the
# system's toplevel runs the module's assertions, and the unit names show that
# the feature switched its units on.
#
# Takes the root flake; returns { drvPath, userUnits, systemUnits }.
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
  systemUnits = builtins.attrNames system.config.systemd.services;
}
