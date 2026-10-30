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
  active = config.oruc.plasma.look == "glass";
in
{
  config = lib.mkIf isPlasma (
    lib.mkMerge [
      {
        home.packages = [
          (pkgs.callPackage ../../../pkgs/oruc-glass-plasma-theme.nix {
            inherit (pkgs.kdePackages) libplasma;
          })
        ];
        # KWin names the effect after its plugin file, glass.so.
        programs.plasma.configFile.kwinrc.Plugins.glassEnabled = active;
      }

      (lib.mkIf active {
        oruc.plasma = {
          widgetStyle = "Glass";
          panelLayout = "islands";
        };

        programs.plasma = {
          workspace.windowDecorations = {
            library = "org.kde.glass";
            theme = "Glass";
          };

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
              # window is opaque, so it loses nothing. SourceGit and Telegram stay
              # unblurred. Telegram's menus are popups, which KWin names after the
              # executable, so the entry is that name; it also matches the main
              # window's resource name.
              # Glass splits the list at newlines and matches each entry exactly
              # against the window's resource class or resource name.
              WindowClasses = lib.concatStringsSep "\n" [
                "Chatgpt"
                "SourceGit"
                "Telegram"
              ];
              Brightness = 0.9;
              Contrast = 1.1;
              BlurStrength = 3;
              EdgeLighting = true;
              # Refraction is off. The zeros are written out because plasma-manager
              # never removes a key it wrote before. RefractionEdgeSize stays,
              # because the edge lighting band reads it even with refraction off.
              RefractionStrength = 0;
              RefractionEdgeSize = 3;
              RefractionRGBFringing = 0;
              TopCornerRadius = 0;
              BottomCornerRadius = 0;
              MenuCornerRadius = 0;
            };
            glassrc.Common.CornerRadius = 0;
          };
        };

        # The opacity and padding of the iglass Frosted theme for Ghostty
        # (https://github.com/vukkt/iglass), with this flake's Base16 colors.
        # The niri sessions read the same Ghostty config.
        programs.ghostty.settings = {
          background-opacity = 0.66;
          window-padding-x = 12;
          window-padding-y = 10;
        };

        # KWin reads Glass's settings only when it loads the effect, and
        # plasma-manager writes kwinrc without telling KWin.
        home.activation.reloadGlass = lib.hm.dag.entryAfter [ "configure-plasma" ] ''
          run ${lib.getExe config.oruc.plasma.reconfigureGlass} \
            || warnEcho "KWin did not reload Glass; it reads the new settings at the next login."
        '';
      })
    ]
  );
}
