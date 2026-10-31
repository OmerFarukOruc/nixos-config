{
  config,
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  images = lib.fileset.toSource {
    root = ../../assets/wallpapers;
    fileset = lib.fileset.fileFilter (
      file:
      lib.any file.hasExt [
        "png"
        "jpg"
        "jpeg"
        "webp"
      ]
    ) ../../assets/wallpapers;
  };
  wallpaperPath = pkgs.writeShellApplication {
    name = "oruc-wallpaper-path";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.lutgen
    ];
    text = ''
      images=${images}
      scheme=$(readlink -e ${lib.escapeShellArg "${config.oruc.themeState}/theme/current"})
      slug=''${scheme##*/}
      for extension in png jpg jpeg webp; do
        if [[ -e $images/$slug.$extension ]]; then
          echo "$images/$slug.$extension"
          exit
        fi
      done
      palette=$(<"$scheme/.oruc/palette")
      key=$(printf '%s\n' "$images" ${pkgs.lutgen} "$palette" | sha256sum | cut -c1-16)
      cache=''${XDG_CACHE_HOME:-$HOME/.cache}/oruc/wallpapers
      out=$cache/$slug-$key.png
      if [[ ! -s $out ]]; then
        mkdir -p "$cache"
        read -ra colors <<<"$palette"
        tmp=$(mktemp --suffix=.png "$cache/.$slug.XXXXXX")
        trap 'rm -f "$tmp"' EXIT
        lutgen apply -R -o "$tmp" "$images/default.png" -- "''${colors[@]}" >/dev/null
        mv -T "$tmp" "$out"
      fi
      echo "$out"
    '';
  };
in
{
  options.oruc.wallpaper = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    default = wallpaperPath;
    description = "oruc-wallpaper-path: prints the wallpaper of the scheme that theme/current points at, the scheme's file in assets/wallpapers or default.png recoloured with its 16 colours, which it renders once per palette, default.png and lutgen into ~/.cache/oruc/wallpapers/<scheme>-<key>.png.";
  };

  config = lib.mkIf (sessions.hasAnyDesktop osConfig.oruc.machine) {
    home.packages = [ wallpaperPath ];
    oruc.themeFacts.palette =
      { scheme, ... }:
      lib.concatMapStringsSep " " (i: scheme.withHashtag."base0${lib.toHexString i}") (
        lib.genList lib.id 16
      )
      + "\n";
  };
}
