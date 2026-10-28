{
  description = "Builds the CachyOS kernel and what OmerFarukOruc's NixOS hosts build against it, for a public Cachix cache";

  inputs.nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/be0be288549209421ab4f67c392a23109cb809a3";

  outputs =
    { nix-cachyos-kernel, ... }:
    let
      pkgs = import nix-cachyos-kernel.inputs.nixpkgs {
        system = "x86_64-linux";
        overlays = [ nix-cachyos-kernel.overlays.pinned ];
        # The NVIDIA package is unfree; only its open kernel module, built from
        # github.com/NVIDIA/open-gpu-kernel-modules, is built and pushed.
        config.allowUnfree = true;
      };
      variants = [
        "x86_64-v3"
        "zen4"
      ];
      kernelPackages =
        variant:
        pkgs.cachyosKernels."linuxPackages-cachyos-latest-lto-${variant}".extend (
          import ./kernel-module-certs.nix pkgs.lib
        );
      nvidiaOpen =
        variant: ((kernelPackages variant).nvidiaPackages.mkDriver (import ./nvidia-driver.nix)).open;
      # What a variant builds besides the kernel and the NVIDIA open module,
      # which every variant builds, by output name. Out-of-tree modules and
      # kernel tools must come from the same kernel package set. List only what
      # the hosts of that variant use, because one failed build keeps the record
      # job from moving every host to the new kernel.
      hostPackages = {
        x86_64-v3 = [ ];
        zen4 = [
          "nct6687d"
          "ryzen-smu"
          "turbostat"
        ];
      };
      packagesFor =
        variant:
        {
          inherit (kernelPackages variant) kernel;
          nvidia-open = nvidiaOpen variant;
        }
        // pkgs.lib.getAttrs hostPackages.${variant} (kernelPackages variant);
      perVariant = pkgs.lib.genAttrs variants (
        variant:
        pkgs.lib.mapAttrs' (name: pkgs.lib.nameValuePair "${name}-${variant}") (packagesFor variant)
      );
    in
    {
      inherit variants;
      installables = builtins.mapAttrs (
        _: ps: builtins.concatStringsSep " " (map (name: ".#${name}^*") (builtins.attrNames ps))
      ) perVariant;
      packages.x86_64-linux = pkgs.lib.mergeAttrsList (builtins.attrValues perVariant);
    };
}
