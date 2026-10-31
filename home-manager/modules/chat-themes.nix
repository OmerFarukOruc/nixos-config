_:
let
  vesktopTheme = ".config/vesktop/themes/oruc.css";
  vesktop =
    { scheme, theme }:
    let
      on = color: "#${theme.readableOn color}";
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
        --button-filled-brand-text: ${on scheme.base0D} !important;
        --button-filled-brand-text-hover: ${on scheme.base03} !important;
        --notice-text-positive: ${on scheme.base0B} !important;
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
