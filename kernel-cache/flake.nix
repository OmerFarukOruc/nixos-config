{
  description = "Builds the CachyOS kernel and what OmerFarukOruc's NixOS hosts build against it, for a public Cachix cache";

  # The release branch only moves after the upstream Hydra built the kernel.
  inputs.nix-cachyos-kernel.url = "github:xddxdd/nix-cachyos-kernel/release";

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
      # One entry per CPU target a host selects (oruc.machine.kernel.profile).
      variants = [
        "x86_64-v3"
        "zen4"
      ];
      kernelPackages = variant: pkgs.cachyosKernels."linuxPackages-cachyos-latest-lto-${variant}";
      # Must match the host's hardware.nvidia.package arguments exactly.
      nvidiaOpen =
        variant:
        ((kernelPackages variant).nvidiaPackages.mkDriver {
          version = "615.78.08";
          sha256_64bit = "sha256-Pj9t3cLudnoIGFMAr3vjyyhuznZpjS3eNSRZl4LQf/4=";
          openSha256 = "sha256-HBINiOjL0ZJLIAJeNIBYHBnwgUXtNwPPtnFpAI1YwF4=";
          settingsSha256 = "sha256-inDRpG02sdDgHmlqgu/DsgK8OFdOt1fZIYyXdhlGC/c=";
          persistencedSha256 = "sha256-RzeR6Ldct6MUxjnXRyThdh5Y3jjMehTVg85MtwuWNX4=";
          # Defers the NVPCF ACPI notify that the firmware sends on every 1 %
          # battery drop, which otherwise wakes a runtime-suspended GPU for
          # about 20 s. The files are the two commits of
          # https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1299, kept in
          # the repository so a rewritten pull request cannot break a rebuild.
          # machines/nixos-rog/graphics.nix applies the same files. Drop them
          # once an NVIDIA release contains the change.
          patchesOpen = [
            ./patches/nvidia-nvpcf-refcount.patch
            ./patches/nvidia-nvpcf-defer.patch
          ];
        }).open;
      # Everything a host builds against the kernel, by output name. Out-of-tree
      # modules and kernel tools must come from the same kernel package set.
      # A variant builds only what its hosts use, because one failed build
      # keeps the record job from moving every host to the new kernel.
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
