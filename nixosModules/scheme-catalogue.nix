{
  inputs,
  lib,
  mkSchemeAttrs,
}:
let
  themeValues = import ./theme-values.nix { inherit lib; };
in
{
  catalogue = lib.mapAttrs (
    slug: parsed:
    let
      scheme = mkSchemeAttrs parsed;
    in
    {
      inherit scheme;
      theme = themeValues scheme // {
        inherit slug;
      };
    }
  ) (import ../machines/schemes.nix { inherit inputs lib; });

  toFile = name: builtins.toFile (lib.strings.sanitizeDerivationName name);
}
