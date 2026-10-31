{ lib, sessions }:
machine:
let
  selectors = import ./selectors.nix;
  hasPlasma = sessions.hasDesktop machine "plasma";
  looks = if hasPlasma then selectors.plasmaLookNames else [ ];
  defaultLook = if hasPlasma then machine.theme.plasmaLook else null;
in
{
  inherit looks defaultLook;
  specialisations = lib.remove defaultLook looks;
}
