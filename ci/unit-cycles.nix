flake: host:
let
  textOnlyUnits =
    lib: utils:
    lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, config, ... }:
          {
            config.unit = lib.mkForce (
              utils.systemdUtils.lib.makeUnit name (
                config // { text = builtins.unsafeDiscardStringContext config.text; }
              )
            );
          }
        )
      );
    };
  system = flake.nixosConfigurations.${host}.extendModules {
    modules = [
      (
        { lib, utils, ... }:
        {
          options.systemd.units = textOnlyUnits lib utils;
          options.systemd.user.units = textOnlyUnits lib utils;
        }
      )
    ];
  };
in
{
  units = system.config.environment.etc."systemd/system".source;
  userUnits = system.config.environment.etc."systemd/user".source;
  systemd = system.config.systemd.package.out;
}
