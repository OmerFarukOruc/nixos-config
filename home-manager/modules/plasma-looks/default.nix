# A Plasma look is one file in this directory that sets the Plasma style, the
# window decoration, the Qt style, the color scheme and the KWin effects that
# belong together. The machine record names the default look
# (theme.plasmaLook). Every other look is a Home Manager specialisation of the
# same generation, which `plasma-look` (nixosModules/plasma-looks.nix)
# activates without a rebuild.
#
# A look writes its keys only while it is active, and plasma-manager never
# removes a key it wrote before. So a look writes its own KWin plugin switches
# as false while another look is active, and nixosModules/plasma-looks.nix
# rejects looks that name different plugin switches.
#
# A specialisation cannot install packages, because NixOS installs the
# packages of the default look only (useUserPackages). So each look installs
# its packages while any look is active.
{
  lib,
  osConfig,
  sessions,
  ...
}:
let
  selectors = import ../../../machines/selectors.nix;
  isPlasma = sessions.hasDesktop osConfig.oruc.machine "plasma";
  defaultLook = osConfig.oruc.machine.theme.plasmaLook;
in
{
  imports = map (name: ./. + "/${name}.nix") selectors.plasmaLookNames;

  options.oruc.plasma = {
    look = lib.mkOption {
      type = lib.types.enum selectors.plasmaLookNames;
      default = defaultLook;
      description = "The Plasma look of this generation.";
    };
    colorScheme = lib.mkOption {
      type = lib.types.str;
      description = "Color scheme that oruc-plasma-colors applies at each Plasma login.";
    };
    widgetStyle = lib.mkOption {
      type = lib.types.str;
      description = "Qt style that oruc-plasma-colors applies at each Plasma login.";
    };
  };

  config = lib.mkIf isPlasma {
    specialisation = lib.genAttrs (lib.remove defaultLook selectors.plasmaLookNames) (look: {
      configuration.oruc.plasma.look = look;
    });
  };
}
