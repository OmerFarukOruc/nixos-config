{
  config,
  inputs,
  lib,
  ...
}:
let
  cfg = config.oruc.machine;
  schema = import ../machines/schema.nix { inherit inputs lib; };
in
{
  options.oruc.machine = schema.machineOption;

  config = {
    # Helpers that answer which desktops and shells this machine offers.
    _module.args.sessions = import ../machines/sessions.nix { inherit lib; };

    networking.hostName = cfg.name;

    assertions = [
      {
        assertion = cfg.system == config.nixpkgs.hostPlatform.system;
        message = "oruc.machine.system must match nixpkgs.hostPlatform.system.";
      }
    ];
  };
}
