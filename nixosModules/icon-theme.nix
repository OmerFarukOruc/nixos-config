{ lib }:
let
  gruvbox = "Gruvbox-Plus";
  other = "Papirus";
in
{
  name =
    scheme: isLight:
    "${if lib.hasPrefix "gruvbox-" scheme.slug then gruvbox else other}-${
      if isLight then "Light" else "Dark"
    }";

  replaceable = [
    "breeze"
    "breeze-dark"
  ]
  ++
    lib.concatMap
      (family: [
        "${family}-Dark"
        "${family}-Light"
      ])
      [
        gruvbox
        other
      ];

  packages = pkgs: [
    pkgs.papirus-icon-theme
    pkgs.gruvbox-plus-icons
    pkgs.fluent-icon-theme
    pkgs.morewaita-icon-theme
    (pkgs.colloid-icon-theme.override {
      schemeVariants = [
        "default"
        "gruvbox"
      ];
      colorVariants = [ "orange" ];
    })
  ];
}
