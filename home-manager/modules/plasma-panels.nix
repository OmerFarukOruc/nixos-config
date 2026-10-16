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
  inherit (osConfig.oruc.theme) wallpaper;

  # Panel Colorizer keeps its whole style in one JSON value, globalSettings,
  # and fills every key left out here from its own defaults. Its typed
  # options in plasma-manager write the setting names of releases before 3,
  # which current releases ignore.
  # The keys are in package/contents/ui/code/globals.js of plasma-panel-colorizer.
  # sourceType 0 is a custom color, 1 a color from the Plasma color scheme.
  colorizer = colorizerWith { };
  colorizerWith = general: style: {
    name = "luisbocanegra.panel.colorizer";
    config.General = general // {
      # The widget shows only in the panel's edit mode.
      hideWidget = true;
      globalSettings = builtins.toJSON style;
    };
  };

  # kVitals keeps its settings in profiles. When the panels are built again,
  # it copies its settings into a new first profile as soon as it loads, which
  # can be before plasma-manager has written them all; a key written later
  # stays out of the profile. So the settings are also the package's defaults
  # (contents/config/main.xml), which the copy reads for a key not yet written.
  # Only the keys that differ from kVitals' own defaults are here.
  # Showing the RTX 4070's sensors keeps it awake (docs/nixos-rog.md, Power and
  # heat), so kVitals shows only the iGPU. ksystemstats numbers GPUs in PCI
  # address order; on nixos-rog, the only hybrid machine, the RTX 4070
  # (0000:65:00.0) comes first, so gpu1 is the Radeon 890M.
  # kVitals colors its own text, so the top bar's accent color reaches it only
  # through fontColor. Its threshold colors still take precedence.
  kvitalsSettings = {
    pinnedMetrics = "cpu/usage,bat/percentage,cpu/freq,cpu/temp,ram/used,uptime/uptime";
    layoutType = "vertical";
    iconSize = 8;
    fontBold = true;
    updateInterval = 1000;
    enableThresholdColors = true;
    labelOpacity = 0.5;
    separatorOpacity = 1;
    useCustomColors = true;
    fontColor = osConfig.scheme.withHashtag.base0D;
  }
  // lib.optionalAttrs (osConfig.oruc.machine.gpu == "hybrid") {
    gpuSelection = "gpu1";
  };
  kvitals = {
    name = "org.kde.plasma.kvitals";
    config.General = kvitalsSettings;
  };
  kvitalsPackage = (pkgs.callPackage ../../pkgs/kvitals.nix { }).overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.xmlstarlet ];
    postInstall =
      (old.postInstall or "")
      + ''
        xml=$out/share/plasma/plasmoids/org.kde.plasma.kvitals/contents/config/main.xml
      ''
      + lib.concatStrings (
        lib.mapAttrsToList (
          key: value:
          let
            text = lib.escapeShellArg (
              if builtins.isBool value then lib.boolToString value else toString value
            );
            entry = "//k:entry[@name='${key}']/k:default";
          in
          ''
            xmlstarlet ed -L -N k=http://www.kde.org/standards/kcfg/1.0 -u "${entry}" -v ${text} "$xml"
            [ "$(xmlstarlet sel -N k=http://www.kde.org/standards/kcfg/1.0 -t -v "${entry}" "$xml")" = ${text} ]
          ''
        ) kvitalsSettings
      );
  });

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

  # This style makes a transparent bar. Each widget sits on its own blurred
  # background with slightly rounded corners and an outline in the accent color,
  # and its text and icons take that color.
  topBarStyle = {
    nativePanel = hiddenNativeBackground;
    widgets.normal = {
      enabled = true;
      blurBehind = true;
      backgroundColor = schemeColor "backgroundColor" "Window" 0.5;
      foregroundColor = schemeColor "highlightColor" "Window" 1;
      radius = {
        enabled = true;
        corner = allCorners 3;
      };
      border = {
        enabled = true;
        width = 1;
        color = schemeColor "highlightColor" "Window" 1;
      };
      # For a widget, margin is the space between its background and its content.
      margin = {
        enabled = true;
        side = {
          top = 6;
          bottom = 6;
          left = 8;
          right = 8;
        };
      };
      spacing = 6;
      shadow.background = softShadow 4;
    };
  };

  # This dock style matches fedora-desktop: one blurred, rounded, faintly tinted
  # background with no outline, icons in the scheme's text color, and popups
  # that float clear of the panel. The blur follows this radius, while
  # fedora-desktop takes its corners from its Plasma theme.
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
      radius = {
        enabled = true;
        corner = allCorners 14;
      };
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

  # The icon and name of the active window's app. The widget's default leaves
  # 10 px after the name. The top bar ends the title with a spacer, so it
  # leaves none. In the floating bar's left island, 6 plus the island's end
  # margin left as much space after the name as before the launcher icon
  # (16 px each in a screenshot of nixos-rog).
  titleBar = rightMargin: {
    applicationTitleBar = {
      layout.elements = [
        "windowIcon"
        "windowTitle"
      ];
      windowTitle = {
        source = "appName";
        hideEmptyTitle = true;
        margins = {
          left = 10;
          right = rightMargin;
          top = 0;
          bottom = 0;
        };
      };
    };
  };

  # The song that Spotify or Brave plays, with its
  # album cover and a play/pause button. The widget hides while no player has
  # a song loaded; a paused song keeps it.
  # plasma-manager's plasmusicToolbar writes some keys that Plasmusic 4 no
  # longer reads, so the keys come from its contents/config/main.xml.
  music = {
    name = "plasmusic-toolbar";
    config.General = {
      # With the automatic choice, Plasma's media multiplexer, the widget
      # stayed hidden while Spotify played and Brave had a stopped player
      # with no song (observed on nixos-rog). These identities come from each
      # player's MPRIS Identity property; another player, such as mpv, shows
      # only once its identity is added here.
      choosePlayerAutomatically = false;
      preferredPlayerIdentity = "Spotify,Brave Origin";
      useAlbumCoverAsPanelIcon = true;
      fallbackToIconWhenArtNotAvailable = true;
      skipBackwardControlInPanel = false;
      skipForwardControlInPanel = false;
    };
  };

  # One floating top panel with no background of its own. Panel Colorizer
  # draws the widgets on blurred, rounded backgrounds with an outline in the
  # accent color. With islandsEnabled it joins each run of widgets that panel
  # spacers separate into one background (utils.js, updateIslandWidgetTypes),
  # so the two spacers make three islands. The spacers stay clear.
  islandsStyle = {
    nativePanel = {
      background.opacity = 0;
      floatingDialogs = true;
      floatingDialogsAllowOverride = true;
    };
    widgets.normal = {
      enabled = true;
      blurBehind = true;
      backgroundColor = schemeColor "backgroundColor" "Window" 0.5;
      foregroundColor = schemeColor "highlightColor" "Window" 1;
      radius = {
        enabled = true;
        corner = allCorners 10;
      };
      border = {
        enabled = true;
        width = 1;
        color = schemeColor "highlightColor" "Window" 1;
      };
      # The title bar fills the panel's height (36 px, read through plasmashell
      # scripting) and the other widgets keep 4 px free above and below
      # (28 px), so the vertical margins give every background the same
      # height. With spacing 0 and side margins instead, the
      # backgrounds of an island meet without a seam and leave 6 px inside
      # each end.
      spacing = 0;
      margin = {
        enabled = true;
        side = {
          top = 4;
          bottom = 4;
          left = 6;
          right = 6;
        };
      };
    };
  };

  dock = {
    location = "bottom";
    height = 80;
    floating = true;
    # The dock hides only while a window overlaps it.
    hiding = "dodgewindows";
    lengthMode = "fit";
    alignment = "center";
    widgets = [
      { iconTasks.launchers = config.oruc.plasma.dockLaunchers; }
      (colorizer dockStyle)
    ];
  };
in
{
  # plasma-manager owns the panels. Whenever this layout changes, it deletes
  # plasma-org.kde.plasma.desktop-appletsrc at the next login and builds the
  # panels again, so a panel or widget change made in Plasma lasts only until then.
  config = lib.mkIf isPlasma {
    home.packages = [
      kvitalsPackage
      pkgs.plasmusic-toolbar
    ];

    programs.plasma = {
      # The panel layout file also holds the wallpaper, so it is set here too.
      workspace = lib.mkIf (wallpaper != null) {
        inherit wallpaper;
        wallpaperFillMode = "preserveAspectCrop";
      };

      panels =
        {
          bar = [
            {
              location = "top";
              height = 44;
              lengthMode = "fill";
              widgets = [
                "org.kde.plasma.kickerdash"
                (titleBar 0)
                # Plasma sizes two expanding spacers so the widget between them sits
                # in the middle of the panel.
                "org.kde.plasma.panelspacer"
                "org.kde.plasma.digitalclock"
                "org.kde.plasma.panelspacer"
                kvitals
                "org.kde.plasma.systemtray"
                "org.kde.plasma.showdesktop"
                (colorizer topBarStyle)
              ];
            }
            dock
          ];
          islands = [
            {
              location = "top";
              height = 36;
              floating = true;
              widgets = [
                "org.kde.plasma.kickerdash"
                (titleBar 6)
                "org.kde.plasma.panelspacer"
                "org.kde.plasma.digitalclock"
                "org.kde.plasma.panelspacer"
                # At the end of the left island, Panel Colorizer drew the song
                # as a box of its own with a double border; here it joins the
                # island.
                music
                kvitals
                "org.kde.plasma.systemtray"
                "org.kde.plasma.showdesktop"
                (colorizerWith { islandsEnabled = true; } islandsStyle)
              ];
            }
            dock
          ];
        }
        .${config.oruc.plasma.panelLayout};
    };
  };
}
