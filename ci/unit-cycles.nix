flake: host:
let
  system = flake.nixosConfigurations.${host}.extendModules {
    modules = [
      (
        { lib, utils, ... }:
        {
          options.systemd.units = lib.mkOption {
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
        }
      )
    ];
  };
in
{
  units = system.config.environment.etc."systemd/system".source;
  systemd = system.config.systemd.package.out;
}
