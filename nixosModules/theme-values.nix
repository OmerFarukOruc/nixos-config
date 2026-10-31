{ lib }:
let
  contrast = import ./contrast.nix { inherit lib; };
  iconTheme = import ./icon-theme.nix { inherit lib; };
in
scheme:
let
  isLight = scheme.scheme-variant == "light";
in
{
  inherit isLight;
  warmBurnout = lib.hasPrefix "warm-burnout-" scheme.scheme-slug;
  polarity = if isLight then "light" else "dark";
  rgb =
    slot:
    map (channel: lib.toInt scheme."${slot}-rgb-${channel}") [
      "r"
      "g"
      "b"
    ];
  cursor = {
    name = if isLight then "Bibata-Modern-Classic" else "Bibata-Modern-Ice";
    size = 24;
  };
  icons = iconTheme.name scheme isLight;
  gtk = if isLight then "adw-gtk3" else "adw-gtk3-dark";
  readableOn = contrast.readableOn scheme;
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
}
