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
  themeFile = ".local/share/vicinae/themes/oruc-base16.toml";
  renderTheme =
    { scheme, theme }:
    let
      color = scheme.withHashtag;
    in
    ''
      [meta]
      version = 1
      name = "Oruc Base16"
      description = "Selected Base16 scheme"
      variant = "${theme.polarity}"
      inherits = "vicinae-${theme.polarity}"

      [colors.core]
      background = "${color.base00}"
      foreground = "${color.base05}"
      secondary_background = "${color.base01}"
      border = "${color.base03}"
      accent = "${color.base0D}"

      [colors.accents]
      blue = "${color.base0D}"
      green = "${color.base0B}"
      magenta = "${color.base0E}"
      orange = "${color.base09}"
      purple = "${color.base0E}"
      red = "${color.base08}"
      yellow = "${color.base0A}"
      cyan = "${color.base0C}"
    '';
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
    };
    oruc.themeFiles.${themeFile} = renderTheme;
    oruc.themeCopies = [ themeFile ];
  };
}
