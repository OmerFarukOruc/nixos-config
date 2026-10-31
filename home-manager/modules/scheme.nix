{ osConfig, ... }:
{
  imports = [ (import ../../nixosModules/theme-module.nix (_: osConfig.oruc.machine.theme.scheme)) ];
}
