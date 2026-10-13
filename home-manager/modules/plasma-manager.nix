{
  config,
  inputs,
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  helpers = import ./launchers/helpers.nix { inherit lib pkgs; };
  isPlasma = sessions.hasDesktop osConfig.oruc.machine "plasma";
  inherit (osConfig.oruc) theme;

  inherit (osConfig.oruc.machine) idle;

  idleDisplay =
    { dimSeconds, screenOffSeconds }:
    {
      DimDisplayWhenIdle = dimSeconds != null;
      TurnOffDisplayWhenIdle = screenOffSeconds != null;
      LockBeforeTurnOffDisplay = false;
    }
    // lib.optionalAttrs (dimSeconds != null) { DimDisplayIdleTimeoutSec = dimSeconds; }
    // lib.optionalAttrs (screenOffSeconds != null) {
      TurnOffDisplayIdleTimeoutSec = screenOffSeconds;
    };
  noAutoSuspend.AutoSuspendAction = 0;
in
{
  imports = [ inputs.plasma-manager.homeModules.plasma-manager ];

  # plasma-manager writes only the keys named here. overrideConfig stays off,
  # because it deletes every Plasma config file that this list does not cover.
  # The Base16 color scheme stays with theme.nix and oruc-plasma-colors, because
  # plasma-manager can only apply a scheme file that already exists.
  config = lib.mkIf isPlasma {
    programs.plasma = {
      enable = true;

      workspace = {
        clickItemTo = "select";
        cursor = {
          inherit (theme.cursor) size;
          theme = theme.cursor.name;
        };
        iconTheme = theme.icons;
        splashScreen.theme = "org.kde.breeze.desktop";
        # The Glass decoration comes with the Glass Qt style; theme.nix turns
        # the style on.
        windowDecorations = {
          library = "org.kde.glass";
          theme = "Glass";
        };
      };

      # The lock screen plays the login screen's video.
      kscreenlocker.appearance.wallpaperCustomPlugin = lib.mkIf (osConfig.oruc.login.video != null) {
        plugin = "luisbocanegra.smart.video.wallpaper.reborn";
        config.General = {
          VideoUrls = builtins.toJSON [
            {
              filename = "file://${osConfig.oruc.login.video}";
              enabled = true;
            }
          ];
          # The lock screen ignores the plugin's window-based pause rules, so
          # the video would keep decoding while the display is off.
          ScreenOffPausesVideo = true;
        };
      };

      # Glass replaces the built-in blur, and KWin names the effect after its
      # plugin file, glass.so. The package comes from nixosModules/desktop.nix.
      kwin = {
        effects = {
          blur.enable = false;
          # Moving past the last desktop wraps to the first.
          desktopSwitching.navigationWrapping = true;
        };
        titlebarButtons = {
          left = [
            "more-window-actions"
            "application-menu"
          ];
          right = [
            "minimize"
            "maximize"
            "close"
          ];
        };
      };
      configFile.kwinrc = {
        # kwin.virtualDesktops would also rename the desktops' IDs to
        # Desktop_N, so KWin keeps its own IDs and their tiling layouts.
        Desktops = {
          Number = 4;
          Rows = 1;
        };
        Plugins.glassEnabled = true;
        # On KWin 6.7 the only blur global is ext_background_effect_manager_v1,
        # and Ghostty 1.3.1 asks only through org_kde_kwin_blur_manager; recheck
        # both when either updates. Glass forces blur behind the see-through
        # pixels of every window only when BlurDecorations is on. Its window
        # class list stays a blacklist, because a whitelist also drops the blur
        # that panels ask for.
        Effect-blurplus = {
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
          # Square window and menu corners, written out because plasma-manager
          # never removes a key it wrote before.
          TopCornerRadius = 0;
          BottomCornerRadius = 0;
          MenuCornerRadius = 0;
        };
        # 9 is no screen edge, so the top-left corner no longer opens Overview.
        Effect-overview.BorderActivate = 9;
        Effect-slide.SlideBackground = false;
      };

      hotkeys.commands =
        let
          bin = "${config.home.profileDirectory}/bin";
        in
        {
          terminal = {
            comment = "Ghostty";
            command = "${bin}/ghostty";
            key = "Meta+Return";
          };
        }
        //
          lib.mapAttrs'
            (
              name: key:
              lib.nameValuePair "launch-${name}" {
                comment = helpers.launchers.${name};
                command = "${bin}/${helpers.binName name}";
                inherit key;
              }
            )
            {
              app = "Meta+Space";
              command = "Meta+Alt+Space";
              ssh = "Meta+Shift+Space";
              file = "Meta+Ctrl+Space";
            };
      # Ghostty's desktop file also claims Ctrl+Alt+T; Konsole lets it go.
      shortcuts."services/org.kde.konsole.desktop"._launch = [ ];

      # The module for web search keywords writes its defaults over the user's
      # web shortcuts whenever plasma-manager is enabled.
      configFile.kuriikwsfilterrc = lib.mkForce { };

      # Plasma's own power profile switch; it is also on Fn+F5 (Launch4) of the
      # ROG laptop, as in the Noctalia and DMS sessions.
      shortcuts.org_kde_powerdevil.powerProfile = [
        "Battery"
        "Meta+B"
        "Launch (4)"
      ];

      # plasma-manager writes powerdevilrc itself, so these files are written
      # here, not linked read-only from the store.
      configFile = {
        spectaclerc = {
          General = {
            autoSaveImage = true;
            clipboardGroup = "PostScreenshotCopyImage";
          };
          ImageSave = {
            imageSaveLocation = "file://${config.home.homeDirectory}/Pictures/Screenshots/";
            preferredImageFormat = "PNG";
            imageFilenameTemplate = "Screenshot_<yyyy><MM><dd>_<HH><mm><ss>";
          };
        };
        # The Glass style and decoration share this radius, so buttons and
        # menus are square too.
        glassrc.Common.CornerRadius = 0;
        kscreenlockerrc.Daemon = {
          Autolock = false;
          Lock = false;
          LockOnResume = false;
          LockOnStart = false;
          Timeout = 0;
        };
        powerdevilrc = {
          "AC/Display" = idleDisplay idle.ac;
          "AC/SuspendAndShutdown" = noAutoSuspend;
          "Battery/Display" = idleDisplay idle.battery;
          "Battery/SuspendAndShutdown" = noAutoSuspend;
          "LowBattery/Display" = idleDisplay idle.battery;
          "LowBattery/SuspendAndShutdown" = noAutoSuspend;
        };
      };
    };

    # The lock screen finds the wallpaper plugin of kscreenlocker's settings
    # above through the user profile.
    home.packages = lib.mkIf (osConfig.oruc.login.video != null) [
      (pkgs.kdePackages.callPackage ../../pkgs/smart-video-wallpaper.nix { })
    ];

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
  };
}
