{ inputs, lib }:
let
  parse = import ./scheme-parser.nix { inherit lib; };
  schemesIn =
    dir:
    lib.pipe (builtins.readDir dir) [
      (lib.filterAttrs (name: _: lib.hasSuffix ".yaml" name))
      (lib.mapAttrs' (
        name: _: lib.nameValuePair (lib.removeSuffix ".yaml" name) (parse (dir + "/${name}"))
      ))
    ];
in
schemesIn "${inputs.base16-schemes}/base16" // schemesIn ../assets/schemes
