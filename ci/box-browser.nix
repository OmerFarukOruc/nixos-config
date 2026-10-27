# nixos-desktop with features.boxBrowser forced on, as a workstation record.
# risoluto-dev-1, a server, has the feature on in its own record. The unit names
# show that the feature switched its units on, and the display's command line
# shows that Xvnc stays on localhost, because with no password the loopback
# bind is its only protection.
#
# Takes the root flake; returns { drvPath, userUnits, displayCommand }.
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
