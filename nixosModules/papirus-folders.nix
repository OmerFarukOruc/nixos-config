{ lib }:
let
  contrast = import ./contrast.nix { inherit lib; };
  colours = {
    adwaita = "3a87e5";
    black = "3f3f3f";
    blue = "4877b1";
    bluegrey = "4d646f";
    breeze = "147eb8";
    brown = "957552";
    carmine = "7a0002";
    cyan = "0096aa";
    darkcyan = "35818a";
    deeporange = "e95420";
    green = "60924b";
    grey = "727272";
    indigo = "3f51b5";
    magenta = "b259b8";
    nordic = "5e81ac";
    orange = "dd772f";
    palebrown = "bea389";
    paleorange = "c89e6b";
    pink = "ec407a";
    red = "bf4b4b";
    teal = "12806a";
    violet = "5d399b";
    white = "cccccc";
    yaru = "973552";
    yellow = "e19d00";
  };
  variants = [
    "Dark"
    "Light"
  ];
  lightnessWeight = 0.25;
  distance = contrast.oklabDistanceSquaredWeighted [
    (lightnessWeight * lightnessWeight)
    1
    1
  ];
  themeName = colour: variant: "Papirus-Oruc-${colour}-${variant}";
  ownKeys = "Name|Comment|Inherits|Directories|ScaledDirectories";
in
{
  nearest =
    hex: contrast.minBy (name: distance (lib.toLower hex) colours.${name}) (builtins.attrNames colours);

  inherit themeName;

  names = lib.concatMap (colour: map (themeName colour) variants) (builtins.attrNames colours);

  package =
    pkgs:
    pkgs.runCommand "papirus-oruc-folders" { } ''
      for variant in ${lib.concatStringsSep " " variants}; do
        base=${pkgs.papirus-icon-theme}/share/icons/Papirus-$variant
        blue=() dirs=()
        for places in "$base"/*/places; do
          mapfile -t links < <(find -H "$places" -maxdepth 1 -type l | sort)
          ((''${#links[@]})) || continue
          mapfile -t resolved < <(realpath -m -- "''${links[@]}")
          dir=''${places#"$base"/}
          count=''${#blue[@]}
          for i in "''${!links[@]}"; do
            [[ ''${resolved[i]##*/} == *-blue[-.]* ]] || continue
            blue+=("$dir/''${links[i]##*/} ''${resolved[i]}")
          done
          ((''${#blue[@]} == count)) || dirs+=("$dir")
        done
        for colour in ${lib.concatStringsSep " " (builtins.attrNames colours)}; do
          theme=$out/share/icons/Papirus-Oruc-$colour-$variant
          for dir in "''${dirs[@]}"; do
            mkdir -p "$theme/$dir"
          done
          for entry in "''${blue[@]}"; do
            link=''${entry%% *} target=''${entry#* }
            name=''${target##*/}
            coloured=''${target%/*}/''${name/-blue/-$colour}
            if [[ ! -e $coloured ]]; then
              echo "Papirus-$variant has no $coloured" >&2
              exit 1
            fi
            ln -s "$coloured" "$theme/$link"
          done
          plain=() scaled=()
          for dir in "''${dirs[@]}"; do
            if [[ $dir == *@* ]]; then scaled+=("$dir"); else plain+=("$dir"); fi
          done
          {
            awk -v keys='^(${ownKeys})=' '/^\[/ { p = ($0 == "[Icon Theme]") } p && NF && !/^#/ && $0 !~ keys' "$base/index.theme"
            printf 'Name=Papirus Oruc %s %s\nComment=Papirus-%s with %s folders\nInherits=Papirus-%s\n' \
              "$colour" "$variant" "$variant" "$colour" "$variant"
            (IFS=,; printf 'Directories=%s\nScaledDirectories=%s\n' "''${plain[*]}" "''${scaled[*]}")
            for dir in "''${dirs[@]}"; do
              printf '\n'
              awk -v section="[$dir]" '$0 == section { p = 1; print; next } /^\[/ { p = 0 } p && NF' "$base/index.theme"
            done
          } >"$theme/index.theme"
        done
      done
    '';
}
