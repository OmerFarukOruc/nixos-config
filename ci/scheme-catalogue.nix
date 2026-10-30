{ inputs }:
let
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  inherit (pkgs) lib;
  schemes = import ../machines/schemes.nix { inherit inputs lib; };
  parsed = lib.mapAttrs (_: scheme: {
    inherit (scheme) name author variant;
    palette = lib.mapAttrs (_: lib.toLower) scheme.palette;
  }) schemes;
in
{
  scheme-catalogue =
    pkgs.runCommand "scheme-catalogue"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.yq-go
        ];
        parsed = builtins.toJSON parsed;
        passAsFile = [ "parsed" ];
      }
      ''
        for file in ${inputs.base16-schemes}/base16/*.yaml ${../assets/schemes}/*.yaml; do
          yq -o=json -I=0 '{"name": .name, "author": .author, "variant": .variant, "palette": (.palette | map_values(downcase))}' "$file" |
            jq -c --arg slug "$(basename "$file" .yaml)" '{($slug): .}'
        done | jq -S -s add >yaml.json
        jq -S . "$parsedPath" >parsed.json
        if ! diff -u yaml.json parsed.json; then
          echo "machines/scheme-parser.nix reads the schemes above differently from yq." >&2
          exit 1
        fi
        touch "$out"
      '';
}
