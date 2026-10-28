# An extension of a kernel package set, for `linuxPackages.extend`.
# aggregateModules merges each external module's `.ko.cer` into `modules.cer`
# and fails on a module without one, or on two packages that ship the same
# depmod index file (nixpkgs pkgs/os-specific/linux/kmod/aggregator.nix).
# Kbuild's `modules_install` signs the module and writes the `.ko.cer`, so both
# packages install through it. Each override drops out once the package set's
# own package does this; for a CachyOS kernel that package comes from
# nix-cachyos-kernel's nixpkgs.
lib: kfinal: kprev: {
  # Kbuild's modules_install runs depmod into $out, and the index files clash
  # with the kernel's. Upstream fix: https://github.com/NixOS/nixpkgs/pull/575861
  v4l2loopback =
    if builtins.elem "DEPMOD=true" (kprev.v4l2loopback.installFlags or [ ]) then
      kprev.v4l2loopback
    else
      kprev.v4l2loopback.overrideAttrs (old: {
        installFlags = (old.installFlags or [ ]) ++ [ "DEPMOD=true" ];
      });

  nct6687d =
    if builtins.elem "DEPMOD=true" (kprev.nct6687d.installFlags or [ ]) then
      kprev.nct6687d
    else
      kprev.nct6687d.overrideAttrs (old: {
        installFlags = (old.installFlags or [ ]) ++ [ "DEPMOD=true" ];
      });

  # The package copies ryzen_smu.ko by hand, so no `.ko.cer` exists.
  ryzen-smu =
    if !lib.hasInfix "install ryzen_smu.ko" (kprev.ryzen-smu.installPhase or "") then
      kprev.ryzen-smu
    else
      kprev.ryzen-smu.overrideAttrs (old: {
        postInstall = (old.postInstall or "") + ''

          rm -r "$out/lib/modules"
          make -C ${kfinal.kernel.dev}/lib/modules/${kfinal.kernel.modDirVersion}/build \
            M="$PWD" ${lib.escapeShellArgs kfinal.kernelModuleMakeFlags} \
            INSTALL_MOD_PATH="$out" INSTALL_MOD_DIR=kernel/drivers/ryzen_smu \
            INSTALL_MOD_STRIP=1 DEPMOD=true modules_install
        '';
      });
}
