{
  config,
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  wallpaperPath = pkgs.writeShellApplication {
    name = "oruc-wallpaper-path";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.lutgen
    ];
    text = ''
      assets=${../../assets/wallpapers}
      facts=${lib.escapeShellArg config.oruc.themeFactsDir}
      slug=$(basename "$(readlink ${lib.escapeShellArg "${config.oruc.themeState}/theme/current"})")
      for extension in png jpg jpeg webp; do
        if [[ -e $assets/$slug.$extension ]]; then
          echo "$assets/$slug.$extension"
          exit
        fi
      done
      cache=''${XDG_CACHE_HOME:-$HOME/.cache}/oruc/wallpapers
      out=$cache/$slug.png
      if [[ ! -s $out ]]; then
        mkdir -p "$cache"
        read -ra colors <"$facts/palette"
        tmp=$(mktemp --suffix=.png "$cache/.$slug.XXXXXX")
        trap 'rm -f "$tmp"' EXIT
        lutgen apply -R -o "$tmp" "$assets/default.png" -- "''${colors[@]}" >/dev/null
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
    description = "oruc-wallpaper-path: prints the wallpaper of the scheme that theme/current points at, the scheme's file in assets/wallpapers or default.png recoloured with its 16 colours, which it renders once into ~/.cache/oruc/wallpapers.";
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
