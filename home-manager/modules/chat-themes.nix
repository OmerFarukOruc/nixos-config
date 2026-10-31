{ lib, ... }:
let
  contrast = import ../../nixosModules/contrast.nix { inherit lib; };
  vesktopTheme = ".config/vesktop/themes/oruc.css";
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
  oruc.themeFiles.${vesktopTheme} = vesktop;
  oruc.themeCopies = [ vesktopTheme ];

  programs.vesktop = {
    enable = true;
    vencord = {
      mutableSettings = true;
      settings.enabledThemes = [ (baseNameOf vesktopTheme) ];
    };
  };
}
