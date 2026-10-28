{
  config,
  lib,
  osConfig,
  sessions,
  ...
}:
let
  scheme = config.scheme.withHashtag;
  theme = config.oruc.theme;
  inherit (theme) isLight wallpaper;

  ansiRow =
    offset:
    lib.listToAttrs (
      lib.imap0 (
        index: name:
        lib.nameValuePair (lib.toLower name) scheme.${builtins.elemAt theme.ansi (offset + index)}
      ) theme.ansiNames
    );
  terminalPalette = {
    foreground = scheme.base05;
    background = scheme.base00;
    cursor = scheme.base05;
    cursorText = scheme.base00;
    selectionFg = scheme.base05;
    selectionBg = scheme.base02;
    normal = ansiRow 0;
    bright = ansiRow 8;
  };
  noctaliaMode = {
    mPrimary = scheme.base0D;
    mOnPrimary = scheme.base00;
    mSecondary = scheme.base0A;
    mOnSecondary = scheme.base00;
    mTertiary = scheme.base0E;
    mOnTertiary = scheme.base00;
    mError = scheme.base08;
    mOnError = scheme.base00;
    mSurface = scheme.base00;
    mOnSurface = scheme.base05;
    mSurfaceVariant = scheme.base01;
    mOnSurfaceVariant = scheme.base04;
    mOutline = scheme.base03;
    mShadow = scheme.base00;
    terminal = terminalPalette;
  };
in
{
  config = lib.mkIf (sessions.hasShell osConfig.oruc.machine "noctalia") {
    oruc.shellServices.noctalia = "noctalia";
    programs.noctalia = {
      enable = true;
      systemd.enable = true;
      checkConfig = true;
      settings = {
        shell.font_family = theme.fonts.mono;
        theme = {
          source = "custom";
          custom_palette = "oruc-base16";
          mode = if isLight then "light" else "dark";
        };
        lockscreen = {
          enabled = false;
          lock_before_suspend = false;
        };
        bar = {
          order = [ "default" ];
          default = {
            position = "top";
            thickness = 34;
            margin_edge = 6;
            margin_ends = 40;
            background_opacity = 0.85;
            start = [
              "launcher-search"
              "workspaces"
              "active_window"
            ];
            center = [ "clock" ];
            end = [
              "cpu"
              "cpu-temp"
              "ram"
              "net-rx"
              "net-tx"
              "keyboard_layout"
              "tray"
              "notifications"
              "network"
              "power_profile"
              "volume"
              "brightness"
              "battery"
              "control-center"
            ];
          };
        };
        widget = {
          launcher-search = {
            type = "custom_button";
            glyph = "search";
            tooltip = "Launcher";
            actions.left = "exec ${config.home.profileDirectory}/bin/oruc-launch-app";
          };
          clock = {
            format = "{:%H:%M}";
            tooltip_format = "{:%A, %d-%m-%Y}";
          };
          cpu = {
            type = "sysmon";
            stat = "cpu_usage";
            visualization = "none";
          };
          cpu-temp = {
            type = "sysmon";
            stat = "cpu_temp";
            visualization = "none";
          };
          ram = {
            type = "sysmon";
            stat = "ram_pct";
            visualization = "none";
          };
          net-rx = {
            type = "sysmon";
            stat = "net_rx";
            visualization = "none";
            network_speed_compact = true;
          };
          net-tx = {
            type = "sysmon";
            stat = "net_tx";
            visualization = "none";
            network_speed_compact = true;
          };
        };
        dock = {
          enabled = true;
          position = "bottom";
          auto_hide = true;
          reserve_space = false;
          background_opacity = 0.85;
          pinned = import ./pinned-apps.nix;
        };
        idle.behavior = {
          lock = {
            enabled = false;
            timeout = 600;
            action = "lock";
          };
          "screen-off" = {
            enabled = false;
            timeout = 660;
            action = "screen_off";
          };
          "lock-and-suspend" = {
            enabled = false;
            timeout = 900;
            action = "lock_and_suspend";
          };
        };
      }
      // {
        wallpaper = {
          enabled = true;
          default.path = toString wallpaper;
          automation.enabled = false;
        };
      };
      customPalettes.oruc-base16 = {
        dark = noctaliaMode;
        light = noctaliaMode;
      };
    };
  };
}
