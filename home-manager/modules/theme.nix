{
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  cfg = osConfig.oruc.machine;
  # base00 and the other slots are hex without "#"; withHashtag adds it.
  rawScheme = osConfig.scheme;
  scheme = osConfig.scheme.withHashtag;
  theme = osConfig.oruc.theme;
  isPlasma = sessions.hasDesktop cfg "plasma";
  isNiri = sessions.hasDesktop cfg "niri";

  vscodeAnsiColors = lib.listToAttrs (
    lib.imap0 (
      index: slot:
      let
        row = if index < 8 then "" else "Bright";
        color = builtins.elemAt theme.ansiNames (lib.mod index 8);
      in
      lib.nameValuePair "terminal.ansi${row}${color}" scheme.${slot}
    ) theme.ansi
  );

  rgb =
    name:
    lib.concatStringsSep "," [
      rawScheme."${name}-rgb-r"
      rawScheme."${name}-rgb-g"
      rawScheme."${name}-rgb-b"
    ];
  kdeColorGroup =
    {
      backgroundNormal,
      backgroundAlternate,
      foregroundNormal,
    }:
    ''
      BackgroundAlternate=${rgb backgroundAlternate}
      BackgroundNormal=${rgb backgroundNormal}
      DecorationFocus=${rgb "base0D"}
      DecorationHover=${rgb "base0D"}
      ForegroundActive=${rgb "base0D"}
      ForegroundInactive=${rgb "base03"}
      ForegroundLink=${rgb "base0D"}
      ForegroundNegative=${rgb "base08"}
      ForegroundNeutral=${rgb "base09"}
      ForegroundNormal=${rgb foregroundNormal}
      ForegroundPositive=${rgb "base0B"}
      ForegroundVisited=${rgb "base0E"}
    '';
  kdeColorScheme = ''
    [ColorEffects:Disabled]
    Color=${rgb "base03"}
    ColorAmount=0
    ColorEffect=0
    ContrastAmount=0.65
    ContrastEffect=1
    IntensityAmount=0.1
    IntensityEffect=2

    [ColorEffects:Inactive]
    ChangeSelectionColor=true
    Color=${rgb "base03"}
    ColorAmount=0.025
    ColorEffect=2
    ContrastAmount=0.1
    ContrastEffect=2
    Enable=false
    IntensityAmount=0
    IntensityEffect=0

    [Colors:Button]
    ${kdeColorGroup {
      backgroundNormal = "base01";
      backgroundAlternate = "base02";
      foregroundNormal = "base05";
    }}
    [Colors:Complementary]
    ${kdeColorGroup {
      backgroundNormal = "base00";
      backgroundAlternate = "base01";
      foregroundNormal = "base05";
    }}
    [Colors:Header]
    ${kdeColorGroup {
      backgroundNormal = "base01";
      backgroundAlternate = "base02";
      foregroundNormal = "base05";
    }}
    [Colors:Header][Inactive]
    ${kdeColorGroup {
      backgroundNormal = "base00";
      backgroundAlternate = "base01";
      foregroundNormal = "base04";
    }}
    [Colors:Selection]
    ${kdeColorGroup {
      backgroundNormal = "base0D";
      backgroundAlternate = "base0C";
      foregroundNormal = "base00";
    }}
    [Colors:Tooltip]
    ${kdeColorGroup {
      backgroundNormal = "base01";
      backgroundAlternate = "base02";
      foregroundNormal = "base05";
    }}
    [Colors:View]
    ${kdeColorGroup {
      backgroundNormal = "base00";
      backgroundAlternate = "base01";
      foregroundNormal = "base05";
    }}
    [Colors:Window]
    ${kdeColorGroup {
      backgroundNormal = "base00";
      backgroundAlternate = "base01";
      foregroundNormal = "base05";
    }}
    [General]
    ColorScheme=OrucBase16
    Name=Oruc Base16
    shadeSortColumn=true

    [KDE]
    contrast=4

    [WM]
    activeBackground=${rgb "base01"}
    activeBlend=${rgb "base01"}
    activeForeground=${rgb "base05"}
    inactiveBackground=${rgb "base00"}
    inactiveBlend=${rgb "base00"}
    inactiveForeground=${rgb "base03"}
  '';
in
{
  fonts.fontconfig.enable = true;

  # These packages provide the families named by oruc.theme.fonts.
  home.packages = with pkgs; [
    inter
    nerd-fonts.jetbrains-mono
    noto-fonts
    noto-fonts-color-emoji
  ];

  programs.ghostty = {
    # Home Manager validates each theme file with an unquoted path, so the
    # theme name must not contain a space.
    themes.oruc-base16 = {
      palette = lib.imap0 (index: slot: "${toString index}=${scheme.${slot}}") theme.ansi;
      background = rawScheme.base00;
      foreground = rawScheme.base05;
      cursor-color = rawScheme.base05;
      selection-background = rawScheme.base02;
      selection-foreground = rawScheme.base05;
    };
    settings.theme = "oruc-base16";
  };

  programs.tmux.extraConfig = ''
    set -g status-style "fg=${scheme.base05},bg=${scheme.base01}"
    set -g window-status-style "fg=${scheme.base04}"
    set -g window-status-current-style "fg=${scheme.base00},bg=${scheme.base0D},bold"
    set -g message-style "fg=${scheme.base05},bg=${scheme.base02}"
    set -g mode-style "fg=${scheme.base05},bg=${scheme.base02}"
    set -g pane-border-style "fg=${scheme.base02}"
    set -g pane-active-border-style "fg=${scheme.base0D}"
  '';

  programs.vscode.profiles.default.userSettings = {
    "workbench.colorTheme" = "Default ${if theme.isLight then "Light" else "Dark"} Modern";
    # vscode.nix sets the see-through backgrounds.
    "workbench.colorCustomizations" = {
      "editor.foreground" = scheme.base05;
      "editor.selectionBackground" = scheme.base02;
      "editorCursor.foreground" = scheme.base05;
      "statusBar.background" = scheme.base02;
      "statusBar.foreground" = scheme.base05;
      "terminal.foreground" = scheme.base05;
    }
    // vscodeAnsiColors;
    # The default ratio of 4.5 shifts terminal colors away from the palette.
    "terminal.integrated.minimumContrastRatio" = 1;
  };

  programs.atuin = {
    settings.theme.name = "Oruc Base16";
    themes.oruc-base16 = {
      theme.name = "Oruc Base16";
      colors = {
        Base = scheme.base05;
        Title = scheme.base0D;
        Important = scheme.base08;
        Guidance = scheme.base04;
        Annotation = scheme.base03;
        AlertInfo = scheme.base0C;
        AlertWarn = scheme.base0A;
        AlertError = scheme.base08;
      };
    };
  };

  programs.nvf.settings.vim.theme = {
    enable = true;
    name = "base16";
    base16-colors = lib.genAttrs (map (n: "base0${n}") (lib.stringToCharacters "0123456789ABCDEF")) (
      slot: scheme.${slot}
    );
  };

  # The link's name needs the wallpaper, so the whole entry is left out when
  # there is none.
  xdg.dataFile =
    lib.optionalAttrs (theme.wallpaper != null) {
      # An attribute name cannot carry the store path's context.
      "backgrounds/oruc/${builtins.unsafeDiscardStringContext (builtins.baseNameOf theme.wallpaper)}".source =
        theme.wallpaper;
    }
    // {
      "color-schemes/OrucBase16.colors" = lib.mkIf (isPlasma || isNiri) {
        text = kdeColorScheme;
      };

      # Plasma's translucent desktop theme has no colors file of its own, and
      # looking one up on every menu and popup slows them down. Plasma only
      # checks that the file exists and never reads it; the colours come from
      # kdeglobals.
      "plasma/desktoptheme/default/translucent/colors" = lib.mkIf isPlasma {
        text = "";
      };
    };

  # The Plasma platform theme reads the scheme that kdeglobals names. Plasma
  # writes kdeglobals itself, so a machine with a Plasma session gets the
  # scheme and icons through oruc-plasma-colors instead.
  xdg.configFile."kdeglobals" = lib.mkIf (isNiri && !isPlasma) {
    text = kdeColorScheme + "\n[Icons]\nTheme=${theme.icons}\n";
  };

  systemd.user.services.oruc-plasma-colors = lib.mkIf isPlasma {
    Unit = {
      Description = "Apply the selected Base16 Plasma color scheme";
      # Only a Plasma session reaches plasma-workspace.target.
      After = [
        "plasma-workspace.target"
        "plasma-plasmashell.service"
      ];
      PartOf = [ "plasma-workspace.target" ];
      # Stop retrying when Plasma keeps rejecting the scheme.
      StartLimitIntervalSec = 60;
      StartLimitBurst = 3;
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${lib.getExe' pkgs.kdePackages.plasma-workspace "plasma-apply-colorscheme"} OrucBase16";
      # The niri session reads the same kdeglobals, so it needs the icon theme too.
      ExecStartPost = lib.mkIf isNiri "${lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6"} --file kdeglobals --group Icons --key Theme ${theme.icons}";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "plasma-workspace.target" ];
  };
}
