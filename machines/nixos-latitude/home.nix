{ pkgs, ... }:
{
  imports = [ ../../home-manager/profiles/workstation.nix ];

  home.packages = [
    # GPU monitor for the Intel iGPU.
    pkgs.nvtopPackages.intel
  ];
}
