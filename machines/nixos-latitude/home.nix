{
  lib,
  osConfig,
  pkgs,
  ...
}:
{
  imports = [ ../../home-manager/profiles/workstation.nix ];

  home.packages = [
    # GPU monitor for the Intel iGPU.
    pkgs.nvtopPackages.intel
  ]
  ++ lib.optional osConfig.oruc.machine.features.remoteDesktop pkgs.remmina;
}
