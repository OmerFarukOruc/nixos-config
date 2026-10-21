# patchelf 0.19.2 writes a binary that segfaults in the dynamic loader when one
# call sets both the interpreter and the rpath, as the NVIDIA driver's builder
# does for nvidia-smi and nvidia-powerd. This overlay provides patchelf 0.15.2
# as patchelf_0_15, and graphics.nix uses it while the driver's package set
# still has patchelf 0.19.2.
#
# The locked nixpkgs already builds CUDA redistributables with patchelf 0.15.2
# (https://github.com/NixOS/nixpkgs/pull/575979), so this overlay does not wrap
# them again.
final: _prev: {
  patchelf_0_15 = final.patchelf.overrideAttrs (
    finalAttrs: _: {
      version = "0.15.2";
      src = final.fetchurl {
        url = "https://github.com/NixOS/patchelf/releases/download/${finalAttrs.version}/patchelf-${finalAttrs.version}.tar.bz2";
        hash = "sha256-F3RfVkFZyOIo/EEtplogSLhGxLa0Igt3y/IkFuAvLXw=";
      };
    }
  );
}
