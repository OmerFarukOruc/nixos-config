{ lib, sessions }:
machine:
let
  selectors = import ./selectors.nix;
  hasPlasma = sessions.hasDesktop machine "plasma";
  looks = if hasPlasma then selectors.plasmaLookNames else [ ];
  generationLook = if hasPlasma then machine.theme.plasmaLook else null;
  rows = map (look: {
    inherit look;
    name = look;
    generation = look == generationLook;
  }) looks;
in
{
  inherit looks rows;
  defaultLook = generationLook;
  specialisations = lib.filter (variant: !variant.generation) rows;
}
