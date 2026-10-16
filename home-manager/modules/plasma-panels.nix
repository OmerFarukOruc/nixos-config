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
  # The keys are in package/contents/ui/code/globals.js of plasma-panel-colorizer.
  # sourceType 0 is a custom color, 1 a color from the Plasma color scheme.
  colorizer = style: {
    name = "luisbocanegra.panel.colorizer";
    config.General = {
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
in
{
  # plasma-manager owns the panels. Whenever this layout changes, it deletes
  # plasma-org.kde.plasma.desktop-appletsrc at the next login and builds the
  # panels again, so a panel or widget change made in Plasma lasts only until then.
  config = lib.mkIf isPlasma {
    home.packages = [ kvitalsPackage ];

    programs.plasma = {
      # The panel layout file also holds the wallpaper, so it is set here too.
      workspace = lib.mkIf (wallpaper != null) {
        inherit wallpaper;
        wallpaperFillMode = "preserveAspectCrop";
      };

      panels = [
        {
          location = "top";
          height = 44;
          lengthMode = "fill";
          widgets = [
            "org.kde.plasma.kickerdash"
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
              # The Teams and WhatsApp Web entries are web apps that Brave
              # writes to ~/.local/share/applications.
              iconTasks.launchers = [
                "preferred://filemanager"
                "applications:io.missioncenter.MissionCenter.desktop"
                "preferred://browser"
                "applications:com.mitchellh.ghostty.desktop"
                "applications:SourceGit.desktop"
                "applications:code.desktop"
                "applications:chatgpt.desktop"
                "applications:com.anthropic.Claude.desktop"
                "applications:grok-bot.desktop"
                "applications:openchamber.desktop"
                "applications:cursor.desktop"
                "applications:org.opengamingcollective.rog-control-center.desktop"
                "applications:slack.desktop"
                "applications:brave-ompifgpmddkgmclendfeacglnodjjndh-Default.desktop"
                "applications:brave-hnpfjngllnobngcgfapefoaidbinmjnm-Default.desktop"
                "applications:discord.desktop"
                "applications:org.telegram.desktop.desktop"
                "applications:spotify.desktop"
                "applications:md.obsidian.Obsidian.desktop"
              ];
            }
            (colorizer dockStyle)
          ];
        }
      ];
    };
  };
}
