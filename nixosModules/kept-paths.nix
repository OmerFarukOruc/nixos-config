# Paths that survive a root reset. Each module names the state it cannot lose;
# a machine with the reset bind-mounts each path from its kept subvolume, and
# other machines ignore the list.
{ config, lib, ... }:
let
  paths = config.oruc.keptPaths;
  nested = lib.filter (path: lib.any (other: lib.hasPrefix "${other}/" path) paths) paths;
in
{
  options.oruc.keptPaths = lib.mkOption {
    type = lib.types.listOf (lib.types.strMatching "/[^ ]*[^/ ]");
    default = [ ];
    description = "Absolute paths of directories or files on / that a root reset keeps.";
  };

  config.assertions = [
    {
      assertion = nested == [ ];
      message = "oruc.keptPaths lists a path inside another kept path: ${lib.concatStringsSep ", " nested}";
    }
  ];
}
