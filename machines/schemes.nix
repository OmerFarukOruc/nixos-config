{
  inputs,
  lib,
  parse ? import ./scheme-parser.nix { inherit lib; },
}:
let
  slugOf = import ./scheme-slug.nix { inherit lib; };
  schemesIn =
    dir:
    lib.mapAttrs' (name: _: lib.nameValuePair (slugOf name) (parse (dir + "/${name}"))) (
      builtins.readDir dir
    );
in
schemesIn "${inputs.base16-schemes}/base16" // schemesIn ../assets/schemes
