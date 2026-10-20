{
  description = "Builds the CachyOS kernel and what OmerFarukOruc's NixOS hosts build against it, for a public Cachix cache";

  # A commit pin on upstream's default branch, whose commits no upstream build
  # tests. Move it only after reading the upstream diff from the old pin
  # (docs/updates.md, The kernel).
  inputs.nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/be0be288549209421ab4f67c392a23109cb809a3";

  outputs =
    { nix-cachyos-kernel, ... }:
    let
      # The pinned overlay builds with the input's own nixpkgs, so these store
      # paths depend only on the nix-cachyos-kernel revision in flake.lock. A
      # host that locks the same revision and uses the pinned overlay gets them
      # from the cache.
      pkgs = import nix-cachyos-kernel.inputs.nixpkgs {
        system = "x86_64-linux";
        overlays = [ nix-cachyos-kernel.overlays.pinned ];
        # The NVIDIA package is unfree; only its open kernel module, built from
        # github.com/NVIDIA/open-gpu-kernel-modules, is built and pushed.
        config.allowUnfree = true;
      };
      # One entry per CPU target; a host selects it with
      # oruc.machine.kernel.profile = "cachyos-latest-lto-<variant>".
      variants = [
        "x86_64-v3"
        "zen4"
      ];
      # The hosts extend their kernel package set with the same file, so the
      # module packages it overrides keep the store paths the hosts use.
      kernelPackages =
        variant:
        pkgs.cachyosKernels."linuxPackages-cachyos-latest-lto-${variant}".extend (
          import ../overlays/kernel-module-certs.nix pkgs.lib
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
        # nixos-rog: hardware.cpu.amd.ryzen-smu and environment.systemPackages.
        zen4 = [
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
      # Output names carry the variant, for example ryzen-smu-zen4.
      perVariant = pkgs.lib.genAttrs variants (
        variant:
        pkgs.lib.mapAttrs' (name: pkgs.lib.nameValuePair "${name}-${variant}") (packagesFor variant)
      );
    in
    {
      inherit variants;
      # The installables that the workflow and build-local.sh build per variant.
      installables = builtins.mapAttrs (
        _: ps: builtins.concatStringsSep " " (map (name: ".#${name}^*") (builtins.attrNames ps))
      ) perVariant;
      packages.x86_64-linux = pkgs.lib.mergeAttrsList (builtins.attrValues perVariant);
    };
}
