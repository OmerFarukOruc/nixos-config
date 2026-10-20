# patchelf 0.19.2 aborts in shiftFile when addDriverRunpath patches some CUDA
# redistributables a second time, such as cuda_gdb and cuda_sanitizer_api.
# nixpkgs master builds them with patchelf 0.15.2 instead
# (https://github.com/NixOS/nixpkgs/pull/575979); this does the same while the
# default patchelf is 0.19.2 and the locked nixpkgs lacks that change.
final: prev:
let
  patchelf = final.patchelf.overrideAttrs (
    finalAttrs: _: {
      version = "0.15.2";
      src = final.fetchurl {
        url = "https://github.com/NixOS/patchelf/releases/download/${finalAttrs.version}/patchelf-${finalAttrs.version}.tar.bz2";
        hash = "sha256-F3RfVkFZyOIo/EEtplogSLhGxLa0Igt3y/IkFuAvLXw=";
      };
    }
  );
  # Read from the source, because evaluating a package to decide which
  # attributes this overlay sets recurses through it.
  fixed = prev.lib.hasInfix "patchelf.overrideAttrs" (
    builtins.readFile (prev.path + "/pkgs/development/cuda-modules/buildRedist/default.nix")
  );
in
prev.lib.optionalAttrs (!fixed) {
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
                nativeBuildInputs = [ patchelf ] ++ old.nativeBuildInputs;
              });
          }
        );
    }
  );
}
