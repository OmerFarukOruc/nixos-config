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
  inherit (config.oruc) theme;

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

  # ksplashqml finds a look-and-feel package by its id under
  # ~/.local/share/plasma/look-and-feel. The files come from the scheme of this
  # Home Manager generation, so each scheme variant carries its own colors.
  splashId = "oruc.splash";
  scheme = config.scheme.withHashtag;
  # ksplashqml sets `stage` from 1 to 5 while the session starts, and quits at 6.
  splashQml = ''
    import QtQuick

    Rectangle {
        id: root
        color: "${scheme.base00}"

        property int stage: 0

        Rectangle {
            id: track
            anchors.horizontalCenter: parent.horizontalCenter
            y: Math.round(parent.height * 0.62)
            width: Math.min(Math.round(parent.width * 0.25), 480)
            height: 6
            radius: height / 2
            color: "${scheme.base01}"

            Rectangle {
                height: parent.height
                radius: parent.radius
                color: "${scheme.base0D}"
                width: Math.round(parent.width * Math.min(root.stage, 5) / 5)
                Behavior on width {
                    NumberAnimation {
                        duration: 600
                        easing.type: Easing.OutCubic
                    }
                }
            }
        }
    }
  '';
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
        splashScreen.theme = splashId;
      };

      # Plasma's default sizes, in the scheme's fonts.
      fonts =
        let
          ui = pointSize: {
            family = theme.fonts.ui;
            inherit pointSize;
          };
        in
        {
          general = ui 10;
          small = ui 8;
          toolbar = ui 10;
          menu = ui 10;
          windowTitle = ui 10;
          fixedWidth = {
            family = theme.fonts.mono;
            pointSize = 10;
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
          # The login theme's BackgroundSpeed in Themes/jake_the_dog.conf.
          PlaybackRate = 1.2;
          # The lock screen ignores the plugin's window-based pause rules, so
          # the video would keep decoding while the display is off. The plugin
          # checks the display by running kscreen-doctor once a second, which
          # costs less CPU than decoding the video.
          ScreenOffPausesVideo = true;
        };
      };

      # The window effects of every look. Each look in plasma-looks/ adds its
      # own blur.
      kwin = {
        effects = {
          # Moving past the last desktop wraps to the first.
          desktopSwitching.navigationWrapping = true;
          windowOpenClose.animation = "glide";
          minimization.animation = "magiclamp";
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
        # 9 is no screen edge, so the top-left corner no longer opens Overview.
        Effect-overview.BorderActivate = 9;
        Effect-slide.SlideBackground = false;

        # plasma-manager deletes a key whose value is null. These keys are left
        # from the Better Blur DX, tiling and macOS Tahoe looks, which are gone.
        Plugins = {
          better_blur_dxEnabled = null;
          krohnkiteEnabled = null;
          liquidglassEnabled = null;
          shapecornersEnabled = null;
        };
        Effect-better-blur-dx.WindowClasses = null;
        Script-krohnkite = lib.genAttrs [
          "floatingClass"
          "screenGapBetween"
          "screenGapBottom"
          "screenGapLeft"
          "screenGapRight"
          "screenGapTop"
        ] (_: null);
      };
      # A window rule deleted in System Settings left its name in the order.
      configFile.kwinrulesrc.General = {
        Order = null;
        rules = null;
      };

      input.keyboard.numlockOnStartup = "on";
      # Apps that start at login come from Home Manager units, such as the
      # Deskflow client, not from the last session.
      session.sessionRestore.restoreOpenApplicationsOnLogin = "startWithEmptySession";
      # nixos-rog has no disk swap, so it cannot hibernate.
      powerdevil.batteryLevels.criticalAction = "sleep";

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
        # Baloo indexes file names only, and skips ~/Desktop/workspace, whose
        # git checkouts, build output and worktrees change all the time. An
        # existing index keeps the file contents it holds until
        # `balooctl6 purge` rebuilds it.
        baloofilerc.General = {
          "only basic indexing" = true;
          "exclude folders" = "${config.home.homeDirectory}/Desktop/workspace/";
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

    xdg.dataFile = {
      "plasma/look-and-feel/${splashId}/metadata.json".text = builtins.toJSON {
        KPackageStructure = "Plasma/LookAndFeel";
        KPlugin = {
          Id = splashId;
          Name = "Oruc splash";
          Description = "Splash screen in the colors of the Base16 scheme";
        };
      };
      "plasma/look-and-feel/${splashId}/contents/splash/Splash.qml".text = splashQml;
    };

    # The lock screen finds the wallpaper plugin of kscreenlocker's settings
    # above through the user profile.
    home.packages = lib.mkIf (osConfig.oruc.login.video != null) [
      (pkgs.kdePackages.callPackage ../../pkgs/smart-video-wallpaper.nix { })
    ];
  };
}
