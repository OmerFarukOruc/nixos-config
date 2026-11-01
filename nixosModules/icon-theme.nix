{ lib }:
let
  gruvbox = "Gruvbox-Plus";
  papirus = "Papirus";
  folders = import ./papirus-folders.nix { inherit lib; };
  variant = isLight: if isLight then "Light" else "Dark";
in
{
  name =
    scheme: isLight:
    if lib.hasPrefix "gruvbox-" scheme.slug then
      "${gruvbox}-${variant isLight}"
    else
      folders.themeName (folders.nearest scheme.base0D) (variant isLight);

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
        papirus
      ]
  ++ folders.names;

  packages = pkgs: [
    pkgs.papirus-icon-theme
    (folders.package pkgs)
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
