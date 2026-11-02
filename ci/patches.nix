{ nixosConfigurations }:
let
  rog = nixosConfigurations.nixos-rog.pkgs;
  inherit (rog) lib;
  patched = {
    xrdp = nixosConfigurations.devbox.pkgs.xrdp;
    inherit (rog.kdePackages) ksystemstats plasma-desktop;
    inherit (rog) sunshine;
    vscode = nixosConfigurations.nixos-rog.config.home-manager.users.oruc.programs.vscode.package;
  };
  patchNeedsTools = [ "vscode" ];
  patchOnly =
    name: pkg:
    (rog.srcOnly pkg).overrideAttrs (old: {
      nativeBuildInputs = if lib.elem name patchNeedsTools then old.nativeBuildInputs else [ ];
      buildInputs = [ ];
      propagatedBuildInputs = [ ];
      installPhase = "touch $out";
    });
  overlayPatches = lib.filterAttrs (
    file: _:
    lib.hasSuffix ".nix" file
    &&
      builtins.length (
        builtins.split "postPatch|fetchpatch|\\.patch[^a-z_]" (builtins.readFile ../overlays/${file})
      ) > 1
  ) (builtins.readDir ../overlays);
  unlisted = lib.filter (file: !patched ? ${lib.removeSuffix ".nix" file}) (
    lib.attrNames overlayPatches
  );
in
{
  patches =
    assert lib.assertMsg (unlisted == [ ])
      "ci/patches.nix: add the package that ${lib.concatStringsSep ", " unlisted} patches to `patched`.";
    rog.linkFarm "patches" (builtins.mapAttrs patchOnly patched);
}
