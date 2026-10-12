{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.oruc.machine.kernel;
  selectors = import ../machines/selectors.nix;
  spec = selectors.kernelSpecs.${cfg.profile};
in
{
  nixpkgs.overlays = [ inputs.nix-cachyos-kernel.overlays.pinned ];
  # CachyOS kernels and NVIDIA open modules that the kernel-cache workflow
  # builds. scripts/update-kernel.sh locks only revisions that cache holds; a
  # plain nix flake update does not check the cache.
  nix.settings = {
    extra-substituters = [ "https://omerfarukoruc.cachix.org" ];
    extra-trusted-public-keys = [
      "omerfarukoruc.cachix.org-1:6OxbnSmF+Agsn0w9aya633NTlxjxXAtsETYNcImB87c="
    ];
  };

  boot.kernelPackages = lib.getAttrFromPath spec.package pkgs;

  assertions = [
    {
      assertion = spec.requiresModule == null || lib.elem spec.requiresModule config.boot.kernelModules;
      message = "Kernel profile ${cfg.profile} needs the kernel module ${toString spec.requiresModule}, but boot.kernelModules does not list it.";
    }
  ];
}
