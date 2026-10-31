{
  config,
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  theme = config.oruc.theme;
  inherit (theme) wallpaper;
  palette = ".config/noctalia/palettes/oruc-base16.json";
  applyScheme = pkgs.writeShellApplication {
    name = "oruc-noctalia-scheme";
    runtimeInputs = [
      pkgs.coreutils
      config.programs.noctalia.package
    ];
    text = ''
      for _ in $(seq 40); do
        noctalia msg theme-mode-get >/dev/null 2>&1 && break
        sleep 0.5
      done
      noctalia msg color-scheme-set custom oruc-base16
      noctalia msg config-reload
      noctalia msg theme-mode-set "$(<${lib.escapeShellArg "${config.oruc.themeFactsDir}/polarity"})"
    '';
  };

  noctaliaMode =
    { scheme, theme }:
    let
      color = scheme.withHashtag;
      ansiRow =
        offset:
        lib.listToAttrs (
          lib.imap0 (
            index: name:
            lib.nameValuePair (lib.toLower name) color.${builtins.elemAt theme.ansi (offset + index)}
          ) theme.ansiNames
        );
    in
    {
      mPrimary = color.base0D;
      mOnPrimary = color.base00;
      mSecondary = color.base0A;
      mOnSecondary = color.base00;
      mTertiary = color.base0E;
      mOnTertiary = color.base00;
      mError = color.base08;
      mOnError = color.base00;
      mSurface = color.base00;
      mOnSurface = color.base05;
      mSurfaceVariant = color.base01;
      mOnSurfaceVariant = color.base04;
      mOutline = color.base03;
      mShadow = color.base00;
      terminal = {
        foreground = color.base05;
        background = color.base00;
        cursor = color.base05;
        cursorText = color.base00;
        selectionFg = color.base05;
        selectionBg = color.base02;
        normal = ansiRow 0;
        bright = ansiRow 8;
      };
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
    };
    oruc.themeFiles.${palette} =
      args:
      builtins.toJSON {
        dark = noctaliaMode args;
        light = noctaliaMode args;
      };
    systemd.user.services.noctalia.Service.ExecStartPost = [ "-${lib.getExe applyScheme}" ];
    oruc.variantReloads.noctalia = ''
      systemctl --user is-active -q noctalia.service || exit 0
      ${lib.getExe applyScheme}
    '';
  };
}
