{ lib, ... }:
let
  contrast = import ../../nixosModules/contrast.nix { inherit lib; };
  vesktopTheme = ".config/vesktop/themes/oruc.css";
  telegramPalette = ".config/oruc/oruc.tdesktop-palette";
  telegramRoles = map (lib.splitString " ") (
    lib.filter (line: line != "") (lib.splitString "\n" (builtins.readFile ./telegram-palette.txt))
  );
  telegram =
    { scheme, theme }:
    let
      colorOf =
        role:
        let
          parts = lib.splitString "/" role;
          base = builtins.head parts;
          alpha = lib.concatStrings (builtins.tail parts);
          value =
            if lib.hasPrefix "#" base then
              lib.removePrefix "#" base
            else if lib.hasPrefix "tint:" base then
              contrast.mixHex 15 scheme.${lib.removePrefix "tint:" base} scheme.base00
            else if lib.hasPrefix "on:" base then
              theme.readableOn scheme.${lib.removePrefix "on:" base}
            else if lib.hasPrefix "fill:" base then
              contrast.fillBehind (theme.readableOn scheme.base0D) 0 scheme.${lib.removePrefix "fill:" base}
            else
              scheme.${base};
        in
        "#${lib.toLower value}${alpha}";
    in
    lib.concatMapStrings (
      row: "${builtins.elemAt row 0}: ${colorOf (builtins.elemAt row 1)};\n"
    ) telegramRoles;
  vesktop =
    { scheme, theme }:
    let
      roles = contrast.textRoles scheme [
        scheme.base00
        scheme.base01
      ];
      text = roles.foreground;
      subtle = roles.dim;
      fill = contrast.fillBehind text;
      vars = {
        text-default = text;
        text-strong = text;
        text-subtle = subtle;
        interactive-text-default = subtle;
        interactive-text-hover = text;
        interactive-text-active = text;
        icon-default = text;
        icon-strong = text;
        icon-subtle = subtle;
        white = text;
        control-primary-background-default = fill 0 scheme.base0D;
        control-primary-background-hover = fill 10 scheme.base0D;
        control-primary-background-active = fill 20 scheme.base0D;
        control-primary-text-default = text;
        control-primary-text-hover = text;
        control-primary-text-active = text;
        blurple-50 = fill 0 scheme.base0D;
        blurple-60 = fill 10 scheme.base0D;
        blurple-65 = fill 20 scheme.base0D;
        badge-primary-background = fill 0 scheme.base0D;
        badge-primary-text = text;
        button-filled-brand-background = fill 0 scheme.base0D;
        button-filled-brand-background-hover = fill 10 scheme.base0D;
        button-filled-brand-text = text;
        button-filled-brand-text-hover = text;
        brand-260 = fill 0 scheme.base0D;
        brand-500 = fill 0 scheme.base0F;
        mention-background = fill 0 scheme.base0D;
        mention-foreground = text;
        green-330 = fill 0 scheme.base0B;
        green-360 = fill 0 scheme.base0B;
        status-positive = fill 0 scheme.base0B;
        status-positive-background = fill 0 scheme.base0B;
        status-positive-text = text;
        notice-text-positive = theme.readableOn scheme.base0B;
        button-danger-background = fill 0 scheme.base08;
        status-danger-background = fill 0 scheme.base08;
        menu-item-danger-hover-bg = fill 0 scheme.base08;
        menu-item-danger-active-bg = fill 10 scheme.base08;
      };
    in
    ''
      /**
       * @name Oruc Base16
       * @author oruc
       * @version 1.0.0
       * @description The stored theme scheme, from nixos-config.
       */
    ''
    + import ./vesktop-colors.nix scheme
    + ''
      .theme-light,
      .theme-dark,
      .theme-darker,
      .theme-midnight,
      .visual-refresh {
        color-scheme: ${theme.polarity};
      ${
        lib.concatStrings (
          lib.mapAttrsToList (name: color: "  --${name}: #${lib.toLower color} !important;\n") vars
        )
      }}

      [class*="addFriend_"],
      [class*="statusActive_"],
      [class*="botTagOP_"] {
        color: var(--white) !important;
      }
    '';
in
{
  oruc.themeFiles = {
    ${vesktopTheme} = vesktop;
    ${telegramPalette} = telegram;
  };
  oruc.themeCopies = [
    vesktopTheme
    telegramPalette
  ];

  programs.vesktop = {
    enable = true;
    vencord = {
      mutableSettings = true;
      settings.enabledThemes = [ (baseNameOf vesktopTheme) ];
    };
  };
}
