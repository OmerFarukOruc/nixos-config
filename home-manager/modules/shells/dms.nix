{
  config,
  lib,
  osConfig,
  inputs,
  sessions,
  ...
}:
let
  inherit (config.oruc.theme) wallpaper;
  themeFile = ".config/dms/oruc-theme.json";
  polarity = "${config.oruc.themeState}/theme/current/.oruc/polarity";

  dmsMode =
    { scheme, ... }:
    let
      color = scheme.withHashtag;
    in
    {
      name = "Base16 ${scheme.scheme-name}";
      surface = color.base00;
      surfaceText = color.base05;
      surfaceVariant = color.base01;
      surfaceVariantText = color.base04;
      background = color.base00;
      backgroundText = color.base05;
      outline = color.base03;
      surfaceContainer = color.base01;
      surfaceContainerHigh = color.base02;
      surfaceContainerHighest = color.base03;
      primary = color.base0D;
      secondary = color.base0A;
      primaryText = color.base00;
      primaryContainer = color.base02;
      surfaceTint = color.base0C;
      error = color.base08;
      warning = color.base09;
      info = color.base0B;
      matugen_type = "scheme-tonal-spot";
    };
in
{
  imports = [ inputs.dms.homeModules.dank-material-shell ];

  config = lib.mkIf (sessions.hasShell osConfig.oruc.machine "dms") {
    oruc.shellServices.dms = "dms";
    oruc.themeFiles.${themeFile} =
      args:
      builtins.toJSON {
        dark = dmsMode args;
        light = dmsMode args;
      };
    oruc.themeCopies = [ themeFile ];
    oruc.variantReloads.dms = ''
      systemctl --user is-active -q dms.service || exit 0
      ${lib.getExe config.programs.dank-material-shell.package} ipc call theme "$(<${lib.escapeShellArg polarity})"
    '';
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
      enableDynamicTheming = false;
      settings = {
        currentThemeName = "custom";
        currentThemeCategory = "custom";
        customThemeFile = "~/${themeFile}";
        runDmsMatugenTemplates = false;
        iconThemeDark = "System Default";
        iconThemeLight = "System Default";
        weatherEnabled = false;
        showWeather = false;
        showDock = true;
        dockAutoHide = false;
        dockSmartAutoHide = true;
        dockTransparency = 0.85;
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
        acLockTimeout = 0;
        batteryLockTimeout = 0;
        acSuspendTimeout = 0;
        batterySuspendTimeout = 0;
        lockBeforeSuspend = false;
      };
      session = {
        locale = "en";
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
