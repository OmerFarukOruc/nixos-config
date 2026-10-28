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
  kwinElectricBorderNone = 9;

  inherit (osConfig.oruc.machine) autoLogin hasBattery idle;

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

      kscreenlocker.appearance.wallpaperCustomPlugin = lib.mkIf (osConfig.oruc.login.video != null) {
        plugin = "luisbocanegra.smart.video.wallpaper.reborn";
        config.General = {
          VideoUrls = builtins.toJSON [
            {
              filename = "file://${osConfig.oruc.login.video}";
              enabled = true;
            }
          ];
          PlaybackRate = 1.2;
          # The lock screen ignores the plugin's window-based pause rules, so
          # the video would keep decoding while the display is off. The plugin
          # checks the display by running kscreen-doctor once a second, which
          # costs less CPU than decoding the video.
          ScreenOffPausesVideo = true;
        };
      };

      kwin = {
        effects = {
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
        Effect-overview.BorderActivate = kwinElectricBorderNone;
        Effect-slide.SlideBackground = false;

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
      input.keyboard.numlockOnStartup = "on";
      session.sessionRestore.restoreOpenApplicationsOnLogin = "startWithEmptySession";
      powerdevil.batteryLevels.criticalAction = lib.mkIf hasBattery "sleep";

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

      shortcuts.org_kde_powerdevil.powerProfile = [
        "Battery"
        "Meta+B"
        "Launch (4)"
      ];

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
        baloofilerc.General = {
          "only basic indexing" = true;
          "exclude folders" = "${config.home.homeDirectory}/Desktop/workspace/";
        };
        klipperrc.General = {
          MaxClipItems = 1;
          KeepClipboardContents = false;
        };
        kiorc.Confirmations = {
          ConfirmDelete = false;
          ConfirmEmptyTrash = false;
        };
        kscreenlockerrc.Daemon = {
          Autolock = false;
          Lock = false;
          LockOnResume = false;
          LockOnStart = autoLogin;
          Timeout = 0;
        };
        powerdevilrc = {
          "AC/Display" = idleDisplay idle.ac;
          "AC/SuspendAndShutdown" = noAutoSuspend;
        }
        // lib.optionalAttrs hasBattery {
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

    home.packages = lib.mkIf (osConfig.oruc.login.video != null) [
      (pkgs.callPackage ../../pkgs/smart-video-wallpaper.nix { })
    ];
  };
}
