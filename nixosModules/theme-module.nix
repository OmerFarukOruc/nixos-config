schemeOf:
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  schemeName = schemeOf config;
  schemes = import ../machines/schemes.nix { inherit inputs lib; };

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
    polarity = readOnly (types.enum [
      "dark"
      "light"
    ]) "The selected scheme's variant, dark or light.";
    rgb = readOnly (types.functionTo (types.listOf types.int)) "The red, green and blue channels, 0 to 255, of a scheme slot such as base00.";
    cursor = {
      name = readOnly types.str "Cursor theme that follows the scheme variant.";
      size = readOnly types.int "Cursor size in pixels.";
    };
    icons = readOnly types.str "Icon theme of the scheme, named by nixosModules/icon-theme.nix: Gruvbox Plus for a gruvbox scheme, else Papirus, each dark or light by the variant.";
    fonts = {
      ui = readOnly types.str "Font family of interface text.";
      mono = readOnly types.str "Nerd Font family of the shell bars.";
    };
    gtk = readOnly types.str "GTK theme that follows the scheme variant.";
    wallpaper = readOnly types.path "Wallpaper named after the selected scheme in assets/wallpapers, or the default wallpaper recolored with the scheme.";
    ansi = readOnly (types.listOf types.str) "Scheme slots of the 16 ANSI colors: black, red, green, yellow, blue, magenta, cyan, white, then the bright row.";
    ansiNames = readOnly (types.listOf types.str) "Capitalized names of the eight ANSI colors, in the order of each row of ansi.";
  };

  config = {
    scheme = schemes.${schemeName};

    oruc.theme = import ./theme-values.nix { inherit lib; } config.scheme // {
      fonts = {
        ui = "Inter";
        mono = "JetBrainsMono Nerd Font";
      };
      wallpaper =
        let
          storePathOfFileAlone =
            file:
            "${
              lib.fileset.toSource {
                root = dirOf file;
                fileset = file;
              }
            }/${baseNameOf file}";
          named = lib.findFirst builtins.pathExists null (
            map (extension: ../assets/wallpapers + "/${schemeName}.${extension}") [
              "png"
              "jpg"
              "jpeg"
              "webp"
            ]
          );
          colors = lib.genList (i: config.scheme.withHashtag."base0${lib.toHexString i}") 16;
          recolored = pkgs.runCommand "wallpaper-${schemeName}" { nativeBuildInputs = [ pkgs.lutgen ]; } ''
            mkdir "$out"
            lutgen apply -R -o "$out/${schemeName}.png" ${storePathOfFileAlone ../assets/wallpapers/default.png} -- ${lib.escapeShellArgs colors}
          '';
        in
        if named == null then "${recolored}/${schemeName}.png" else storePathOfFileAlone named;
    };
  };
}
