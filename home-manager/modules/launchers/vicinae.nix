{
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  cfg = osConfig.oruc.machine;
  selected = sessions.hasAnyDesktop cfg && cfg.launcher == "vicinae";
  helpers = import ./helpers.nix { inherit lib pkgs; };
  scheme = osConfig.scheme.withHashtag;
  inherit (osConfig.oruc.theme) isLight;
  commands = {
    app = "exec ${lib.getExe pkgs.vicinae} toggle";
    command = "exec ${lib.getExe pkgs.vicinae} deeplink vicinae://launch/system/run";
    ssh = helpers.sshVia "${lib.getExe pkgs.vicinae} dmenu";
    file = "exec ${lib.getExe pkgs.vicinae} deeplink vicinae://launch/files/search";
  };
in
{
  config = lib.mkIf selected {
    home.packages = helpers.packagesFor commands;

    programs.vicinae = {
      enable = true;
      systemd.enable = true;
      enableFirefoxIntegration = false;
      settings = {
        launcher_window = {
          opacity = 0.85;
          size = {
            width = 1100;
            height = 680;
          };
          layer_shell.enabled = true;
        };
        theme = {
          dark.name = "oruc-base16";
          light.name = "oruc-base16";
        };
      };
      themes.oruc-base16 = {
        meta = {
          version = 1;
          name = "Oruc Base16";
          description = "Selected Base16 Gruvbox palette";
          variant = if isLight then "light" else "dark";
          inherits = if isLight then "vicinae-light" else "vicinae-dark";
        };
        colors = {
          core = {
            background = scheme.base00;
            foreground = scheme.base05;
            secondary_background = scheme.base01;
            border = scheme.base03;
            accent = scheme.base0D;
          };
          accents = {
            blue = scheme.base0D;
            green = scheme.base0B;
            magenta = scheme.base0E;
            orange = scheme.base09;
            purple = scheme.base0E;
            red = scheme.base08;
            yellow = scheme.base0A;
            cyan = scheme.base0C;
          };
        };
      };
    };
  };
}
