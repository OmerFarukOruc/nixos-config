{ lib, sessions }:
machine:
let
  selectors = import ./selectors.nix;
  hasPlasma = sessions.hasDesktop machine "plasma";
  schemes = lib.unique ([ machine.theme.scheme ] ++ machine.theme.schemes);
  looks = if hasPlasma then selectors.plasmaLookNames else [ ];
  name = look: scheme: lib.concatStringsSep "_" (lib.optional (look != null) look ++ [ scheme ]);
  generationScheme = machine.theme.scheme;
  generationLook = if hasPlasma then machine.theme.plasmaLook else null;
  row =
    look: scheme:
    {
      inherit scheme;
      name = name look scheme;
      generation = scheme == generationScheme && look == generationLook;
    }
    // lib.optionalAttrs (look != null) { inherit look; };
  rows =
    if hasPlasma then
      lib.concatMap (look: map (scheme: row look scheme) schemes) looks
    else
      map (scheme: row null scheme) schemes;
in
{
  inherit
    looks
    schemes
    name
    rows
    ;
  defaultScheme = generationScheme;
  defaultLook = generationLook;
  specialisations = lib.filter (variant: !variant.generation) rows;
}
