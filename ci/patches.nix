{ nixosConfigurations }:
let
  rog = nixosConfigurations.nixos-rog.pkgs;
  inherit (rog) lib;
  patched = {
    xrdp = nixosConfigurations.devbox.pkgs.xrdp;
    inherit (rog.kdePackages) ksystemstats plasma-desktop;
    inherit (rog) sunshine;
  };
  patchOnly =
    name: pkg:
    pkg.overrideAttrs {
      pname = "${name}-patches";
      outputs = [ "out" ];
      separateDebugInfo = false;
      nativeBuildInputs = [ ];
      buildInputs = [ ];
      propagatedBuildInputs = [ ];
      phases = [
        "unpackPhase"
        "patchPhase"
        "installPhase"
      ];
      installPhase = "touch $out";
    };
in
{
  patches = rog.linkFarm "patches" (
    lib.mapAttrsToList (name: pkg: {
      inherit name;
      path = patchOnly name pkg;
    }) patched
  );
}
