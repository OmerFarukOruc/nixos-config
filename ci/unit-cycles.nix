# A host's /etc/systemd/system without the programs its units start, so the
# pre-push hook can check the boot order without fetching the whole system. Each unit file
# keeps its text, but its store paths no longer pull their closures in. The
# packages that ship upstream units are still fetched, because their unit files
# hold part of the ordering, such as power-profiles-daemon's
# After=multi-user.target.
#
# Takes the root flake and a host name; returns { units, systemd }.
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
