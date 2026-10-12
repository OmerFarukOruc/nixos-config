{
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  isPlasma = sessions.hasDesktop osConfig.oruc.machine "plasma";
  inherit (osConfig.oruc.theme) wallpaper;

  # Panel Colorizer keeps its whole style in one JSON value, globalSettings,
  # and fills every key left out here from its own defaults. Its typed
  # options in plasma-manager write the setting names of releases before 3,
  # which current releases ignore.
  # The keys: package/contents/ui/code/globals.js in plasma-panel-colorizer.
  # sourceType 0 is a custom color, 1 a color from the Plasma color scheme.
  colorizer = style: {
    name = "luisbocanegra.panel.colorizer";
    config.General = {
      # The widget shows only in the panel's edit mode.
      hideWidget = true;
      globalSettings = builtins.toJSON style;
    };
  };

  allCorners = value: {
    topLeft = value;
    topRight = value;
    bottomLeft = value;
    bottomRight = value;
  };
  schemeColor = systemColor: systemColorSet: alpha: {
    enabled = true;
    sourceType = 1;
    inherit systemColor systemColorSet alpha;
  };
  softShadow = size: {
    enabled = true;
    inherit size;
    xOffset = 0;
    yOffset = 1;
    color = {
      sourceType = 0;
      custom = "#000000";
      alpha = 0.3;
    };
  };
  # Hides Plasma's own panel background, so only the colorizer draws one.
  hiddenNativeBackground.background = {
    opacity = 0;
    shadow = false;
  };

  # A transparent bar with each widget on its own blurred, rounded background.
  topBarStyle = {
    nativePanel = hiddenNativeBackground;
    widgets.normal = {
      enabled = true;
      blurBehind = true;
      backgroundColor = schemeColor "backgroundColor" "Window" 0.75;
      radius = {
        enabled = true;
        corner = allCorners 10;
      };
      margin = {
        enabled = true;
        side = {
          top = 4;
          bottom = 4;
        };
      };
      spacing = 6;
      shadow.background = softShadow 4;
    };
  };

  # The dock style of fedora-desktop: one blurred, square, faintly tinted
  # background with no outline, icons in the scheme's text color, and
  # popups that float clear of the panel.
  dockStyle = {
    nativePanel = {
      background.opacity = 0;
      floatingDialogs = true;
      floatingDialogsAllowOverride = true;
    };
    panel.normal = {
      enabled = true;
      blurBehind = true;
      backgroundColor = schemeColor "backgroundColor" "View" 0.1;
      padding = {
        enabled = true;
        side = {
          left = 2;
          right = 2;
        };
      };
    };
    widgets.normal = {
      enabled = true;
      foregroundColor = schemeColor "textColor" "View" 1;
    };
  };
in
{
  # plasma-manager owns the panels. Whenever this layout changes, it deletes
  # plasma-org.kde.plasma.desktop-appletsrc at the next login and builds the
  # panels again, so a panel or widget change made in Plasma lasts only until then.
  config = lib.mkIf isPlasma {
    home.packages = [ (pkgs.callPackage ../../pkgs/kvitals.nix { }) ];

    programs.plasma = {
      # The panel layout file also holds the wallpaper, so it is set here too.
      workspace = lib.mkIf (wallpaper != null) {
        inherit wallpaper;
        wallpaperFillMode = "preserveAspectCrop";
      };

      panels = [
        {
          location = "top";
          height = 34;
          lengthMode = "fill";
          widgets = [
            "org.kde.plasma.kickerdash"
            "org.kde.plasma.pager"
            "org.kde.plasma.panelspacer"
            "org.kde.plasma.digitalclock"
            "org.kde.plasma.panelspacer"
            "org.kde.plasma.kvitals"
            "org.kde.plasma.systemtray"
            "org.kde.plasma.showdesktop"
            (colorizer topBarStyle)
          ];
        }
        {
          location = "bottom";
          height = 80;
          floating = true;
          # The dock hides only while a window overlaps it.
          hiding = "dodgewindows";
          lengthMode = "fit";
          alignment = "center";
          widgets = [
            {
              # The Teams entry is the web app that Brave writes to
              # ~/.local/share/applications.
              iconTasks.launchers = [
                "applications:systemsettings.desktop"
                "preferred://filemanager"
                "preferred://browser"
                "applications:brave-ompifgpmddkgmclendfeacglnodjjndh-Default.desktop"
                "applications:chatgpt.desktop"
              ];
            }
            (colorizer dockStyle)
          ];
        }
      ];
    };
  };
}
