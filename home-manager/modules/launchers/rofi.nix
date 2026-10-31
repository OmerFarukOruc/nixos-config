{
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
  themeFile = ".local/share/rofi/themes/custom.rasi";
  renderTheme =
    { scheme, ... }:
    let
      color = scheme.withHashtag;
    in
    ''
      * {
      background-color: ${color.base00};
      border-color: ${color.base0D};
      foreground-color: ${color.base05};
      selected-normal-background: ${color.base02};
      selected-normal-foreground: ${color.base07};
      }

      window {
      border: 2;
      border-radius: 10;
      padding: 12;
      width: 42%;
      }
    '';
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
      theme = "custom";
    };
    oruc.themeFiles.${themeFile} = renderTheme;
  };
}
