{ nixosConfigurations }:
let
  rog = nixosConfigurations.nixos-rog.pkgs;
  inherit (rog) lib;
  patched = {
    xrdp = nixosConfigurations.devbox.pkgs.xrdp;
    graphics = nixosConfigurations.nixos-rog.config.hardware.nvidia.package.open;
    inherit (rog.kdePackages) ksystemstats;
    inherit (rog)
      iptvnator
      power-profiles-daemon
      scx-loader
      sunshine
      ;
    vscode = nixosConfigurations.nixos-rog.config.home-manager.users.oruc.programs.vscode.package;
  };
  fixedUp = {
    proton-ge-bin = rog.proton-ge-bin.steamcompattool;
    agent-skills =
      nixosConfigurations.nixos-rog.config.home-manager.users.oruc.oruc.agents.upstreamSkills;
  };
  patchTools = {
    vscode = [
      rog.jq
      rog.asar
    ];
  };
  unpackAndPatchAttrs = [
    "__structuredAttrs"
    "name"
    "src"
    "srcs"
    "sourceRoot"
    "setSourceRoot"
    "unpackCmd"
    "preUnpack"
    "unpackPhase"
    "postUnpack"
    "patches"
    "patchFlags"
    "prePatch"
    "patchPhase"
    "postPatch"
  ];
  patchOnly =
    name: pkg:
    (rog.srcOnly (
      lib.getAttrs (lib.filter (attr: pkg.drvAttrs ? ${attr}) unpackAndPatchAttrs) pkg.drvAttrs
      // {
        stdenv = rog.stdenvNoCC;
        nativeBuildInputs = patchTools.${name} or [ ];
      }
    )).overrideAttrs
      { installPhase = "touch $out"; };
  unchecked = {
    deskflow = "it only drops the patches of libportal, which libportal 0.10.0 already contains";
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
  moduleName =
    file:
    if baseNameOf file == "default.nix" then
      baseNameOf (dirOf file)
    else
      lib.removeSuffix ".nix" (baseNameOf file);
  unlisted = lib.filter (name: !(patched ? ${name} || fixedUp ? ${name} || unchecked ? ${name})) (
    map moduleName patchingFiles
  );
in
{
  patches =
    assert lib.assertMsg (unlisted == [ ])
      "ci/patches.nix: list the package that ${lib.concatStringsSep ", " unlisted} patches in `patched`, a package it edits after the build in `fixedUp`, or the file in `unchecked` with the reason.";
    rog.linkFarm "patches" (builtins.mapAttrs patchOnly patched // fixedUp);
}
