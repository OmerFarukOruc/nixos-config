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
  fixedUp = {
    proton-ge-bin = rog.proton-ge-bin.steamcompattool;
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
  unchecked = {
    deskflow = "it only drops the patches of libportal, which libportal 0.10.0 already contains";
    nvidia-driver = "it patches the driver version that file pins, which no nixpkgs move changes";
  };
  patchingFiles =
    lib.filter
      (
        file:
        lib.hasSuffix ".nix" file
        &&
          builtins.length (
            builtins.split "(pre|post)(Unpack|Patch|Fixup)|patches = |fetchpatch|\\.(patch|diff)([^a-z_]|$)" (
              builtins.readFile file
            )
          ) > 1
      )
      (
        lib.concatMap lib.filesystem.listFilesRecursive [
          ../overlays
          ../home-manager
          ../nixosModules
          ../machines
        ]
      );
  unlisted = lib.filter (
    file:
    let
      name = lib.removeSuffix ".nix" file;
    in
    !(patched ? ${name} || fixedUp ? ${name} || unchecked ? ${name})
  ) (map baseNameOf patchingFiles);
in
{
  patches =
    assert lib.assertMsg (unlisted == [ ])
      "ci/patches.nix: list the package that ${lib.concatStringsSep ", " unlisted} patches in `patched`, a package it edits after the build in `fixedUp`, or the file in `unchecked` with the reason.";
    rog.linkFarm "patches" (builtins.mapAttrs patchOnly patched // fixedUp);
}
