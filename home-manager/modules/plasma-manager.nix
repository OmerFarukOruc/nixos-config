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
      };

      # Better Blur DX replaces the built-in blur, and KWin names the effect after
      # its plugin file, better_blur_dx.so. The package comes from nixosModules/desktop.nix.
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
        Plugins.better_blur_dxEnabled = true;
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

      # Plasma's own power profile switch, also on Fn+F5 (Launch4) of the ROG
      # laptop, as in the niri sessions.
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
  };
}
