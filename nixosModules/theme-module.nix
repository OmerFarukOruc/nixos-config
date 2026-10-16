# The Base16 scheme and the read-only oruc.theme values that follow it. NixOS
# (theme.nix) and Home Manager (home-manager/modules/scheme.nix) both import
# it, each with the function that reads its scheme name from its config.
schemeOf:
{
  config,
  inputs,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;
  schemeName = schemeOf config;
  schemes = import ../machines/schemes.nix { inherit inputs lib; };
  isLight = config.scheme.scheme-variant == "light";

  readOnly =
    type: description:
    mkOption {
      inherit type description;
      readOnly = true;
    };
in
{
  imports = [ inputs.base16.nixosModule ];

  options.oruc.theme = {
    isLight = readOnly types.bool "Whether the selected scheme is a light variant.";
    cursor = {
      name = readOnly types.str "Cursor theme that follows the scheme variant.";
      size = readOnly types.int "Cursor size in pixels.";
    };
    icons = readOnly types.str "Icon theme that follows the scheme variant.";
    fonts = {
      ui = readOnly types.str "Font family of interface text.";
      mono = readOnly types.str "Nerd Font family of the shell bars.";
    };
    gtk = readOnly types.str "GTK theme that follows the scheme variant.";
    wallpaper = readOnly (types.nullOr types.path) "Wallpaper named after the selected scheme in assets/wallpapers, or null when none exists.";
    ansi = readOnly (types.listOf types.str) "Scheme slots of the 16 ANSI colors: black, red, green, yellow, blue, magenta, cyan, white, then the bright row.";
    ansiNames = readOnly (types.listOf types.str) "Capitalized names of the eight ANSI colors, in the order of each row of ansi.";
  };

  config = {
    scheme = schemes.${schemeName};

    oruc.theme = {
      inherit isLight;
      cursor = {
        name = if isLight then "Bibata-Modern-Classic" else "Bibata-Modern-Ice";
        size = 24;
      };
      icons = if isLight then "Papirus-Light" else "Papirus-Dark";
      fonts = {
        ui = "Inter";
        mono = "JetBrainsMono Nerd Font";
      };
      gtk = if isLight then "adw-gtk3" else "adw-gtk3-dark";
      wallpaper =
        let
          file = lib.findFirst builtins.pathExists null (
            map (extension: ../assets/wallpapers + "/${schemeName}.${extension}") [
              "png"
              "jpg"
              "jpeg"
              "webp"
            ]
          );
          # A copy of the one file, because a path inside the flake makes every
          # change to this repository a new wallpaper store path.
          copy = lib.fileset.toSource {
            root = dirOf file;
            fileset = file;
          };
        in
        if file == null then null else "${copy}/${baseNameOf file}";
      ansiNames = [
        "Black"
        "Red"
        "Green"
        "Yellow"
        "Blue"
        "Magenta"
        "Cyan"
        "White"
      ];
      ansi = [
        "base00"
        "base08"
        "base0B"
        "base0A"
        "base0D"
        "base0E"
        "base0C"
        "base05"
        "base03"
        "base08"
        "base0B"
        "base0A"
        "base0D"
        "base0E"
        "base0C"
        "base07"
      ];
    };
  };
}
