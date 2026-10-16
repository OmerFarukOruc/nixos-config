# The Home Manager variants of oruc (machines/variants.nix). The generation
# itself has the machine record's scheme and default Plasma look; each other
# variant is a specialisation, which `theme` and `plasma-look`
# (nixosModules/hm-variants.nix) activate without a rebuild.
#
# A specialisation cannot install packages, because NixOS installs the packages
# of the generation itself (useUserPackages). So a color reaches an app through
# a file that Home Manager writes, never through a package built with it;
# nixosModules/hm-variants.nix fails the evaluation when a specialisation's
# packages differ.
{
  lib,
  osConfig,
  sessions,
  ...
}:
let
  variants = import ../../machines/variants.nix { inherit lib sessions; } osConfig.oruc.machine;
in
{
  specialisation = lib.listToAttrs (
    map (
      variant:
      lib.nameValuePair variant.name {
        configuration.oruc = {
          inherit (variant) scheme;
        }
        // lib.optionalAttrs (variant.look != null) { plasma.look = variant.look; };
      }
    ) variants.specialisations
  );
}
