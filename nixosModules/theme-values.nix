{ lib }:
scheme:
let
  isLight = scheme.scheme-variant == "light";
in
{
  inherit isLight;
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
  icons = (import ./icon-theme.nix { inherit lib; }).name scheme isLight;
  gtk = if isLight then "adw-gtk3" else "adw-gtk3-dark";
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
