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
  options.oruc.variantReloads = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Commands the variant activator runs after a switch. Empty when no app reloads.";
  };

  config.specialisation = lib.listToAttrs (
    map (
      variant:
      lib.nameValuePair variant.name {
        configuration.oruc = {
          inherit (variant) scheme;
        }
        // lib.optionalAttrs (variant ? look) { plasma.look = variant.look; };
      }
    ) variants.specialisations
  );
}
