# The Home Manager variants of a machine: one per Plasma look and scheme. The
# variant of the default look and the record's scheme is the Home Manager
# generation itself; each other one is a specialisation of it, which
# `plasma-look` and `theme` activate (nixosModules/hm-variants.nix). A machine
# without Plasma has no looks, so its variants differ only by scheme.
{ lib, sessions }:
machine:
let
  looks =
    if sessions.hasDesktop machine "plasma" then (import ./selectors.nix).plasmaLookNames else [ null ];
  defaultLook = if sessions.hasDesktop machine "plasma" then machine.theme.plasmaLook else null;
  schemes = lib.unique ([ machine.theme.scheme ] ++ machine.theme.schemes);
  # The shell in nixosModules/hm-variants.nix builds the same name.
  name = look: scheme: lib.concatStringsSep "_" (lib.optional (look != null) look ++ [ scheme ]);
in
{
  inherit
    looks
    defaultLook
    schemes
    name
    ;
  defaultScheme = machine.theme.scheme;
  # Each specialisation, as { name, look, scheme }.
  specialisations = lib.filter (variant: variant.name != name defaultLook machine.theme.scheme) (
    map (variant: variant // { name = name variant.look variant.scheme; }) (
      lib.cartesianProduct {
        look = looks;
        scheme = schemes;
      }
    )
  );
}
