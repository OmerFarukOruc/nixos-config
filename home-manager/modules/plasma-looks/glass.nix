# The Glass look: the Glass window decoration, Qt style and KWin effect, the
# translucent Base16 scheme and a Plasma style with see-through popups. Another
# look can build on the same parts through oruc.plasma.glass.
{
  config,
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  isPlasma = sessions.hasDesktop osConfig.oruc.machine "plasma";
  glass = config.oruc.plasma.glass;
  active = glass.enable;
  radius = glass.cornerRadius;
in
{
  options.oruc.plasma.glass = {
    enable = lib.mkEnableOption "the Glass decoration, Qt style, KWin effect and Plasma style";
    cornerRadius = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = "Corner radius of windows, menus and buttons, in pixels.";
    };
  };

  config = lib.mkIf isPlasma (
    lib.mkMerge [
      {
        # The Glass decoration, style and effect come from nixosModules/desktop.nix.
        home.packages = [
          (pkgs.callPackage ../../../pkgs/oruc-glass-plasma-theme.nix {
            inherit (pkgs.kdePackages) libplasma;
          })
        ];
        # KWin names the effect after its plugin file, glass.so.
        programs.plasma.configFile.kwinrc.Plugins.glassEnabled = active;
      }

      (lib.mkIf (config.oruc.plasma.look == "glass") { oruc.plasma.glass.enable = true; })

      (lib.mkIf active {
        oruc.plasma = {
          colorScheme = "OrucBase16Glass";
          widgetStyle = "Glass";
        };

        programs.plasma = {
          workspace = {
            theme = "oruc-glass";
            # The Glass decoration comes with the Glass Qt style.
            windowDecorations = {
              library = "org.kde.glass";
              theme = "Glass";
            };
          };

          # Glass replaces the built-in blur.
          kwin.effects.blur.enable = false;

          configFile = {
            # On KWin 6.7 the only blur global is ext_background_effect_manager_v1,
            # and Ghostty 1.3.1 asks only through org_kde_kwin_blur_manager; recheck
            # both when either updates. Glass forces blur behind the see-through
            # pixels of every window only when BlurDecorations is on. Its window
            # class list stays a blacklist, because a whitelist also drops the blur
            # that panels ask for.
            kwinrc.Effect-blurplus = {
              BlurDecorations = true;
              # In blacklist mode these window classes get no blur. The ChatGPT
              # app draws its pet in a clear window 1460x3080 px in size, and the
              # forced blur turned that whole window into a dark pane. Its main
              # window is opaque, so it loses nothing. SourceGit stays unblurred.
              # Glass splits the list at newlines and matches each entry exactly
              # against the window's resource class or resource name.
              WindowClasses = lib.concatStringsSep "\n" [
                "Chatgpt"
                "SourceGit"
              ];
              # The values of the dark-glass mode in 4v3ngR/glassOS switcher/theme,
              # with the glow taken from the scheme's blue.
              Brightness = 0.9;
              Contrast = 1.1;
              BlurStrength = 3;
              EdgeLighting = true;
              # Glass reads #AARRGGBB, so 10 is the alpha.
              GlowColor = "#10${osConfig.scheme.base0D}";
              # Refraction is off. The zeros are written out because plasma-manager
              # never removes a key it wrote before. RefractionEdgeSize stays,
              # because the edge lighting band reads it even with refraction off.
              RefractionStrength = 0;
              RefractionEdgeSize = 3;
              RefractionRGBFringing = 0;
              # Written out even when 0, because plasma-manager never removes a
              # key it wrote before.
              TopCornerRadius = radius;
              BottomCornerRadius = radius;
              MenuCornerRadius = radius;
            };
            # The Glass style and decoration share this radius, so buttons and
            # menus follow the windows.
            glassrc.Common.CornerRadius = radius;
          };
        };

        # KWin reads Glass's settings only when it loads the effect, and
        # plasma-manager writes kwinrc without telling KWin. With no Plasma session
        # running, KWin is not on the user bus, and the next login reads the file.
        home.activation.reloadGlass =
          let
            busctl = lib.getExe' pkgs.systemd "busctl";
          in
          lib.hm.dag.entryAfter [ "configure-plasma" ] ''
            if ${busctl} --user status org.kde.KWin >/dev/null 2>&1; then
              run ${busctl} --user call org.kde.KWin /Effects org.kde.kwin.Effects \
                reconfigureEffect s glass \
                || warnEcho "KWin did not reload Glass; it reads the new settings at the next login."
            fi
          '';
      })
    ]
  );
}
