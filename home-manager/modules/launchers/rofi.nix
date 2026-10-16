{
  config,
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  cfg = osConfig.oruc.machine;
  selected = sessions.hasAnyDesktop cfg && cfg.launcher == "rofi";
  helpers = import ./helpers.nix { inherit lib pkgs; };
  scheme = config.scheme.withHashtag;
  rasi = config.lib.formats.rasi;
  commands = {
    app = "exec ${lib.getExe pkgs.rofi} -show drun";
    command = "exec ${lib.getExe pkgs.rofi} -show run";
    ssh = "exec ${lib.getExe pkgs.rofi} -show ssh";
    file = "exec ${lib.getExe pkgs.rofi} -show filebrowser";
  };
in
{
  config = lib.mkIf selected {
    home.packages = helpers.packagesFor commands;

    programs.rofi = {
      enable = true;
      settings.terminal = helpers.terminal;
      theme = {
        "*" = {
          background-color = rasi.mkLiteral scheme.base00;
          foreground-color = rasi.mkLiteral scheme.base05;
          border-color = rasi.mkLiteral scheme.base0D;
          selected-normal-background = rasi.mkLiteral scheme.base02;
          selected-normal-foreground = rasi.mkLiteral scheme.base07;
        };
        window = {
          border = 2;
          border-radius = 10;
          padding = 12;
          width = rasi.mkLiteral "42%";
        };
      };
    };
  };
}
