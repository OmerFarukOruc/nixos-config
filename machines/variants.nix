# The Home Manager variants of a machine. With Plasma, one row per look and
# scheme. Without Plasma, one row per scheme, and that row has no look. The
# row of the record's scheme, and of theme.plasmaLook when the machine has
# Plasma, is the Home Manager generation. Each other row is a specialisation,
# which `plasma-look` and `theme` activate (nixosModules/hm-variants.nix).
# `name` is the only encoder of a specialisation's directory. The shell reads
# the finished rows and does not rebuild them.
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
