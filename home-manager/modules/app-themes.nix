{
  config,
  lib,
  osConfig,
  ...
}:
let
  contrast = import ../../nixosModules/contrast.nix { inherit lib; };
  home = config.home.homeDirectory;
  hex = color: "#${lib.toLower color}";
  inherit (contrast) decimal;
  polarityName = theme: lib.toSentenceCase theme.polarity;

  konsoleScheme = "OrucBase16";
  konsole =
    { scheme, theme }:
    let
      slot = name: scheme.${name};
      faint = color: contrast.mixHex 70 color scheme.base00;
      ansi = map slot theme.ansi;
      colour = index: builtins.elemAt ansi index;
      groups = {
        Foreground = scheme.base05;
        Background = scheme.base00;
        ForegroundIntense = scheme.base07;
        BackgroundIntense = scheme.base00;
        ForegroundFaint = faint scheme.base05;
        BackgroundFaint = scheme.base00;
      }
      // lib.listToAttrs (
        lib.concatMap (index: [
          (lib.nameValuePair "Color${toString index}" (colour index))
          (lib.nameValuePair "Color${toString index}Intense" (colour (index + 8)))
          (lib.nameValuePair "Color${toString index}Faint" (faint (colour index)))
        ]) (lib.range 0 7)
      );
    in
    lib.generators.toINI { } (
      {
        General = {
          Description = "Oruc Base16";
          Opacity = 1;
        };
      }
      // lib.mapAttrs (_: color: { Color = decimal color; }) groups
    );

  thunderbird =
    { scheme, theme }:
    let
      vars = {
        "--layout-background-0" = scheme.base00;
        "--layout-background-1" = scheme.base01;
        "--layout-background-2" = scheme.base01;
        "--layout-background-3" = scheme.base02;
        "--layout-background-4" = scheme.base03;
        "--layout-color-0" = scheme.base07;
        "--layout-color-1" = scheme.base05;
        "--layout-color-2" = scheme.base04;
        "--layout-color-3" = scheme.base04;
        "--layout-border-0" = scheme.base02;
        "--layout-border-1" = scheme.base03;
        "--layout-border-2" = scheme.base03;
        "--tree-view-bg" = scheme.base00;
        "--tree-view-color" = scheme.base05;
        "--toolbox-background-color" = scheme.base01;
        "--toolbox-text-color" = scheme.base05;
        "--spaces-bg-color" = scheme.base01;
        "--selected-item-color" = scheme.base0D;
        "--selected-item-text-color" = theme.readableOn scheme.base0D;
        "--link-color" = scheme.base0D;
        "--color-accent-primary" = scheme.base0D;
        "--background-color-canvas" = scheme.base00;
        "--background-color-box" = scheme.base01;
        "--text-color" = scheme.base05;
      };
    in
    ''
      :root {
        color-scheme: ${theme.polarity} !important;
      ${
        lib.concatStrings (lib.mapAttrsToList (name: color: "  ${name}: ${hex color} !important;\n") vars)
      }}
    '';

  obsidian =
    { scheme, theme }:
    let
      vars = {
        "--background-primary" = scheme.base00;
        "--background-primary-alt" = scheme.base01;
        "--background-secondary" = scheme.base01;
        "--background-secondary-alt" = scheme.base02;
        "--background-modifier-border" = scheme.base02;
        "--background-modifier-border-hover" = scheme.base03;
        "--background-modifier-border-focus" = scheme.base0D;
        "--background-modifier-form-field" = scheme.base01;
        "--text-normal" = scheme.base05;
        "--text-muted" = scheme.base04;
        "--text-faint" = scheme.base03;
        "--text-on-accent" = theme.readableOn scheme.base0D;
        "--text-on-accent-inverted" = theme.readableOn scheme.base0D;
        "--color-accent" = scheme.base0D;
        "--color-accent-1" = contrast.mixHex 80 scheme.base0D scheme.base05;
        "--color-accent-2" = contrast.mixHex 60 scheme.base0D scheme.base05;
        "--text-accent" = scheme.base0D;
        "--text-accent-hover" = scheme.base0C;
        "--interactive-normal" = scheme.base02;
        "--interactive-hover" = scheme.base03;
        "--interactive-accent" = scheme.base0D;
        "--interactive-accent-hover" = scheme.base0C;
        "--text-selection" = contrast.mixHex 30 scheme.base0D scheme.base00;
        "--text-highlight-bg" = contrast.mixHex 35 scheme.base0A scheme.base00;
        "--text-error" = scheme.base08;
        "--text-warning" = scheme.base09;
        "--text-success" = scheme.base0B;
        "--color-red" = scheme.base08;
        "--color-orange" = scheme.base09;
        "--color-yellow" = scheme.base0A;
        "--color-green" = scheme.base0B;
        "--color-cyan" = scheme.base0C;
        "--color-blue" = scheme.base0D;
        "--color-purple" = scheme.base0E;
        "--color-pink" = scheme.base0F;
      };
    in
    ''
      body.theme-dark,
      body.theme-light {
        color-scheme: ${theme.polarity};
      ${lib.concatStrings (lib.mapAttrsToList (name: color: "  ${name}: ${hex color};\n") vars)}}
    '';

  argb = color: "#FF${lib.toUpper color}";
  sourcegit =
    { scheme, theme }:
    builtins.toJSON {
      BasicColors =
        lib.mapAttrs (_: argb) {
          Window = scheme.base00;
          WindowBorder = scheme.base03;
          TitleBar = scheme.base01;
          ToolBar = scheme.base01;
          Popup = scheme.base01;
          PopupBorder = scheme.base02;
          Contents = scheme.base00;
          Badge = scheme.base03;
          BadgeFG = theme.readableOn scheme.base03;
          Conflict = scheme.base0A;
          "Conflict.Foreground" = theme.readableOn scheme.base0A;
          Border0 = scheme.base01;
          Border1 = scheme.base03;
          Border2 = scheme.base02;
          "FlatButton.Background" = scheme.base01;
          "FlatButton.BackgroundHovered" = scheme.base02;
          "FlatButton.FloatingBorder" = scheme.base03;
          FG1 = scheme.base05;
          FG2 = scheme.base04;
          "Diff.AddedHighlight" = contrast.mixHex 45 scheme.base0B scheme.base00;
          "Diff.DeletedHighlight" = contrast.mixHex 45 scheme.base08 scheme.base00;
          "Diff.BlockBorderHighlight" = scheme.base0C;
          Link = scheme.base0D;
          InlineCode = scheme.base02;
          InlineCodeFG = scheme.base05;
          SubPanel = scheme.base01;
          SystemAccentColor = scheme.base0D;
        }
        // {
          "Diff.AddedBG" = "#C0${lib.toUpper (contrast.mixHex 30 scheme.base0B scheme.base00)}";
          "Diff.DeletedBG" = "#C0${lib.toUpper (contrast.mixHex 30 scheme.base08 scheme.base00)}";
        };
      GraphColors = map argb [
        scheme.base0D
        scheme.base0B
        scheme.base0A
        scheme.base08
        scheme.base0E
        scheme.base0C
        scheme.base09
        scheme.base0F
      ];
    };
  sourcegitFile = ".config/oruc/sourcegit-theme.json";

  obsidianFile = ".config/oruc/obsidian.css";
  thunderbirdFile = ".config/oruc/thunderbird.css";
  thunderbirdProfiles = "${config.xdg.configHome}/thunderbird/profiles.ini";
in
{
  oruc.themeFiles = {
    ".local/share/konsole/${konsoleScheme}.colorscheme" = konsole;
    ${thunderbirdFile} = thunderbird;
    ${obsidianFile} = obsidian;
    ${sourcegitFile} = sourcegit;
  };
  oruc.themeFacts = {
    sourcegit-settings =
      { theme, ... }:
      builtins.toJSON {
        Theme = polarityName theme;
        ThemeOverrides = "${home}/${sourcegitFile}";
      };
    obsidian-settings =
      { theme, ... }:
      builtins.toJSON {
        enabledCssSnippets = [ "oruc-scheme" ];
        theme = if theme.polarity == "dark" then "obsidian" else "moonstone";
      };
    jadx-settings = { theme, ... }: builtins.toJSON { lafTheme = "FlatLaf ${polarityName theme}"; };
  };

  programs.konsole = {
    enable = true;
    defaultProfile = "Oruc";
    profiles.Oruc = {
      colorScheme = konsoleScheme;
      font.name = osConfig.oruc.theme.fonts.mono;
    };
  };

  oruc.appSettings = {
    thunderbird = {
      label = "Thunderbird";
      profiles = thunderbirdProfiles;
      files = [
        {
          path = "{profile}/chrome/userChrome.css";
          format = "copy";
          source = thunderbirdFile;
          live = true;
        }
        {
          path = "{profile}/user.js";
          format = "userjs";
          values."toolkit.legacyUserProfileCustomizations.stylesheets" = true;
          live = true;
        }
      ];
    };
    obsidian = {
      label = "Obsidian";
      commandLines = [ ''/obsidian-[^/ ]+/share/obsidian/app\.asar'' ];
      vaults = "${config.xdg.configHome}/obsidian/obsidian.json";
      files = [
        {
          path = "{vault}/.obsidian/snippets/oruc-scheme.css";
          format = "copy";
          source = obsidianFile;
          live = true;
        }
        {
          path = "{vault}/.obsidian/appearance.json";
          format = "json";
          fact = "obsidian-settings";
        }
      ];
    };
    sourcegit = {
      label = "SourceGit";
      executables = [
        {
          package = "sourcegit";
          path = "lib/sourcegit/SourceGit";
        }
      ];
      files = [
        {
          path = "${config.xdg.configHome}/SourceGit/preference.json";
          format = "json";
          fact = "sourcegit-settings";
          create = false;
        }
      ];
    };
    jadx = {
      label = "jadx";
      commandLines = [ ''-jar \S*/jadx-[^/ ]*-all\.jar'' ];
      files = [
        {
          path = "${config.xdg.configHome}/jadx/gui.json";
          format = "json";
          fact = "jadx-settings";
          create = false;
        }
      ];
    };
  };
}
