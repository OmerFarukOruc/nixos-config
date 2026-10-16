{
  config,
  lib,
  osConfig,
  pkgs,
  inputs,
  sessions,
  ...
}:
let
  scheme = config.scheme.withHashtag;
  theme = config.oruc.theme;
  inherit (theme) wallpaper;

  dmsMode = {
    name = "Base16 ${config.scheme.scheme-name}";
    surface = scheme.base00;
    surfaceText = scheme.base05;
    surfaceVariant = scheme.base01;
    surfaceVariantText = scheme.base04;
    background = scheme.base00;
    backgroundText = scheme.base05;
    outline = scheme.base03;
    surfaceContainer = scheme.base01;
    surfaceContainerHigh = scheme.base02;
    surfaceContainerHighest = scheme.base03;
    primary = scheme.base0D;
    secondary = scheme.base0A;
    primaryText = scheme.base00;
    primaryContainer = scheme.base02;
    surfaceTint = scheme.base0C;
    error = scheme.base08;
    warning = scheme.base09;
    info = scheme.base0B;
    matugen_type = "scheme-tonal-spot";
  };
  dmsTheme = (pkgs.formats.json { }).generate "oruc-base16-dms.json" {
    dark = dmsMode;
    light = dmsMode;
  };
in
{
  imports = [ inputs.dms.homeModules.dank-material-shell ];

  config = lib.mkIf (sessions.hasShell osConfig.oruc.machine "dms") {
    oruc.shellServices.dms = "dms";
    # dms-open hands a page or link to the DMS app picker, which runs only in
    # niri. Plasma once picked it for an HTML file, and the open failed.
    xdg.mimeApps.associations.removed = lib.genAttrs [
      "text/html"
      "application/xhtml+xml"
      "x-scheme-handler/http"
      "x-scheme-handler/https"
    ] (_: [ "dms-open.desktop" ]);
    programs.dank-material-shell = {
      enable = true;
      systemd.enable = true;
      # Colors come from the scheme, not from matugen.
      enableDynamicTheming = false;
      settings = {
        currentThemeName = "custom";
        currentThemeCategory = "custom";
        customThemeFile = toString dmsTheme;
        runDmsMatugenTemplates = false;
        iconThemeDark = theme.icons;
        iconThemeLight = theme.icons;
        weatherEnabled = false;
        showWeather = false;
        showDock = true;
        # The dock reserves no space. It hides only while a window covers it, and
        # hovering the bottom edge reveals it.
        dockAutoHide = false;
        dockSmartAutoHide = true;
        dockTransparency = 0.85;
        # The whole default entry is written, because a partial entry does not
        # merge with the defaults.
        barConfigs = [
          {
            id = "default";
            name = "Main Bar";
            enabled = true;
            position = 0;
            screenPreferences = [ "all" ];
            showOnLastDisplay = true;
            leftWidgets = [
              "launcherButton"
              "workspaceSwitcher"
              "focusedWindow"
            ];
            centerWidgets = [
              "music"
              "clock"
            ];
            rightWidgets = [
              "systemTray"
              "cpuUsage"
              "cpuTemp"
              "memUsage"
              "diskUsage"
              "network_speed_monitor"
              "keyboard_layout_name"
              "notificationButton"
              "battery"
              "controlCenterButton"
            ];
            spacing = 4;
            innerPadding = 4;
            barLengthPadding = 0;
            bottomGap = 0;
            attachToScreenEdge = false;
            transparency = 0.85;
            widgetTransparency = 1.0;
            squareCorners = false;
            noBackground = false;
            maximizeWidgetIcons = false;
            maximizeWidgetText = false;
            removeWidgetPadding = false;
            widgetPadding = 8;
            batteryColorMode = "theme";
            gothCornersEnabled = false;
            gothCornerRadiusOverride = false;
            gothCornerRadiusValue = 12;
            borderEnabled = false;
            borderColor = "surfaceText";
            borderOpacity = 1.0;
            borderThickness = 1;
            widgetOutlineEnabled = false;
            widgetOutlineColor = "primary";
            widgetOutlineOpacity = 1.0;
            widgetOutlineThickness = 1;
            fontScale = 1.0;
            iconScale = 1.0;
            autoHide = false;
            autoHideStrict = false;
            autoHideDelay = 250;
            showOnWindowsOpen = false;
            openOnOverview = false;
            visible = true;
            popupGapsAuto = true;
            popupGapsManual = 4;
            maximizeDetection = true;
            useOverlayLayer = false;
            scrollEnabled = true;
            scrollXBehavior = "column";
            scrollYBehavior = "workspace";
            shadowIntensity = 0;
            shadowOpacity = 60;
            shadowColorMode = "default";
            shadowCustomColor = "#000000";
            clickThrough = false;
            hoverPopouts = false;
            hoverPopoutDelay = 150;
          }
        ];
        # DMS idle stays off. swayidle in idle.nix handles idle and screen off
        # for every niri session. The values pin the DMS defaults.
        acLockTimeout = 0;
        batteryLockTimeout = 0;
        acSuspendTimeout = 0;
        batterySuspendTimeout = 0;
        lockBeforeSuspend = false;
      };
      session = {
        # Without this DMS follows the Qt locale, which picks up tr_TR.
        locale = "en";
        # Pinning in the DMS window does not persist, because this file is read-only.
        pinnedApps = import ./pinned-apps.nix;
      }
      // {
        wallpaperPath = toString wallpaper;
        wallpaperPathDark = toString wallpaper;
        wallpaperPathLight = toString wallpaper;
      };
    };
  };
}
