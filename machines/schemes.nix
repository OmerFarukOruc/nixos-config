# The file of every base16 scheme, by name: the pinned tinted-theming schemes
# input and this repository's own schemes in assets/schemes. A name in both
# takes this repository's file.
{ inputs, lib }:
let
  schemesIn =
    dir:
    lib.pipe (builtins.readDir dir) [
      (lib.filterAttrs (name: _: lib.hasSuffix ".yaml" name))
      (lib.mapAttrs' (name: _: lib.nameValuePair (lib.removeSuffix ".yaml" name) (dir + "/${name}")))
    ];
in
schemesIn "${inputs.base16-schemes}/base16" // schemesIn ../assets/schemes
