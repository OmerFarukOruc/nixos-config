# patchelf 0.19.2 breaks NVIDIA binaries in two ways, so they build with
# patchelf 0.15.2, which this overlay provides as patchelf_0_15:
# - It aborts in shiftFile when addDriverRunpath patches some CUDA
#   redistributables a second time, such as cuda_gdb and cuda_sanitizer_api.
#   nixpkgs master builds them with patchelf 0.15.2
#   (https://github.com/NixOS/nixpkgs/pull/575979); the extension below does the
#   same while the default patchelf is 0.19.2 and the locked nixpkgs lacks that
#   change.
# - It writes a binary that segfaults in the dynamic loader when one call sets
#   both the interpreter and the rpath, as the NVIDIA driver's builder does for
#   nvidia-smi and nvidia-powerd. graphics.nix handles the driver.
final: prev:
let
  # Read from the source, because evaluating a package to decide which
  # attributes this overlay sets recurses through it.
  fixed = prev.lib.hasInfix "patchelf.overrideAttrs" (
    builtins.readFile (prev.path + "/pkgs/development/cuda-modules/buildRedist/default.nix")
  );
in
{
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
// prev.lib.optionalAttrs (!fixed) {
  _cuda = prev._cuda.extend (
    _: prevAttrs: {
      # Inside the extension, where reading patchelf's version is safe.
      extensions =
        prevAttrs.extensions
        ++ prev.lib.optional (final.patchelf.version == "0.19.2") (
          _: cprev: {
            buildRedist =
              args:
              (cprev.buildRedist args).overrideAttrs (old: {
                nativeBuildInputs = [ final.patchelf_0_15 ] ++ old.nativeBuildInputs;
              });
          }
        );
    }
  );
}
