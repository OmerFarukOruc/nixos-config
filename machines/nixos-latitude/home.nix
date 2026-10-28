{ pkgs, ... }:
{
  imports = [ ../../home-manager/profiles/workstation.nix ];

  home.packages = [
    pkgs.nvtopPackages.intel
  ];
}
