{
  inputs,
  lib,
  osConfig,
  ...
}:
let
  schemeNames = lib.attrNames (import ../../machines/schemes.nix { inherit inputs lib; });
in
{
  imports = [ (import ../../nixosModules/theme-module.nix (config: config.oruc.scheme)) ];

  options.oruc.scheme = lib.mkOption {
    type = lib.types.enum schemeNames;
    default = osConfig.oruc.machine.theme.scheme;
    description = "The Base16 scheme of this Home Manager generation.";
  };
}
