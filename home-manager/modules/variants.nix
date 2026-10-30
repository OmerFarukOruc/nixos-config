{
  config,
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
    type = lib.types.attrsOf lib.types.str;
    default = { };
    description = "Commands, by app name, that theme and plasma-look run after a switch so running apps load the new colours. Each exits non-zero when its reload failed.";
  };

  config.specialisation = lib.listToAttrs (
    map (
      variant:
      lib.nameValuePair variant.name {
        configuration.oruc = {
          inherit (variant) scheme;
          themePack = lib.mkForce config.oruc.themePack;
        }
        // lib.optionalAttrs (variant ? look) { plasma.look = variant.look; };
      }
    ) variants.specialisations
  );
}
