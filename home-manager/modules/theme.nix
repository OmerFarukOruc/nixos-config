{
  config,
  inputs,
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

  # A warm-burnout-* scheme brings Warm Burnout's own VS Code and Neovim
  # themes, which color syntax beyond the 16 Base16 slots.
  isWarmBurnout = lib.hasPrefix "warm-burnout-" cfg.theme.scheme;
  warmBurnoutVariant = if theme.isLight then "light" else "dark";
  warmBurnoutVersion = (lib.importJSON "${inputs.warm-burnout}/vscode/package.json").version;
  warmBurnoutVscode = pkgs.vscode-utils.buildVscodeExtension {
    pname = "felip3fdl-warm-burnout";
    version = warmBurnoutVersion;
    src = inputs.warm-burnout;
    sourceRoot = "source/vscode";
    vscodeExtPublisher = "felip3fdl";
    vscodeExtName = "warm-burnout";
    vscodeExtUniqueId = "felip3fdl.warm-burnout";
  };
  warmBurnoutNvim = pkgs.vimUtils.buildVimPlugin {
    pname = "warm-burnout";
    version = warmBurnoutVersion;
    src = "${inputs.warm-burnout}/nvim";
  };

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
  # KDE reads a fourth number as the alpha, from 0 (clear) to 255 (opaque).
  # The Glass Qt style draws windows with these backgrounds, and the Glass
  # KWin effect blurs what shows through.
  rgba = name: alpha: "${rgb name},${toString alpha}";
  kdeColorGroup =
    {
      backgroundNormal,
      backgroundAlternate,
      foregroundNormal,
      translucent ? false,
    }:
    ''
      BackgroundAlternate=${if translucent then rgba backgroundAlternate 80 else rgb backgroundAlternate}
      BackgroundNormal=${if translucent then rgba backgroundNormal 140 else rgb backgroundNormal}
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
  opaqueScheme = kdeColorScheme false;
  glassScheme = kdeColorScheme true;
  applyColorScheme = lib.getExe' pkgs.kdePackages.plasma-workspace "plasma-apply-colorscheme";
  kwriteconfig = lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6";
  setWidgetStyle = style: "${kwriteconfig} --file kdeglobals --group KDE --key widgetStyle ${style}";
  iconTheme = "${kwriteconfig} --file kdeglobals --group Icons --key Theme ${theme.icons}";

  colorsOnce = import ./plasma-looks/once-per-login.nix { inherit lib pkgs; } "oruc-plasma-colors";

  # The glass scheme makes the window and view backgrounds translucent.
  kdeColorScheme = glass: ''
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
      translucent = glass;
    }}
    [Colors:Window]
    ${kdeColorGroup {
      backgroundNormal = "base00";
      backgroundAlternate = "base01";
      foregroundNormal = "base05";
      translucent = glass;
    }}
    [General]
    ColorScheme=OrucBase16${lib.optionalString glass "Glass"}
    Name=Oruc Base16${lib.optionalString glass " Glass"}
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

  oruc.vscodeSettings = {
    "workbench.colorTheme" =
      if isWarmBurnout then
        "Warm Burnout ${lib.toSentenceCase warmBurnoutVariant}"
      else
        "Default ${if theme.isLight then "Light" else "Dark"} Modern";
    # vscode.nix sets the see-through backgrounds. The terminal takes
    # Ghostty's colors.
    "workbench.colorCustomizations" =
      lib.optionalAttrs (!isWarmBurnout) {
        "editor.foreground" = scheme.base05;
        "editor.selectionBackground" = scheme.base02;
        "editorCursor.foreground" = scheme.base05;
        "statusBar.background" = scheme.base02;
        "statusBar.foreground" = scheme.base05;
      }
      // {
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

  programs.vscode.profiles.default.extensions = lib.optional isWarmBurnout warmBurnoutVscode;

  programs.nvf.settings.vim.extraPlugins = lib.mkIf isWarmBurnout {
    warm-burnout = {
      package = warmBurnoutNvim;
      setup = "vim.cmd.colorscheme('warm-burnout-${warmBurnoutVariant}')";
    };
  };

  programs.nvf.settings.vim.theme = lib.mkIf (!isWarmBurnout) {
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
        text = opaqueScheme;
      };
      "color-schemes/OrucBase16Glass.colors" = lib.mkIf isPlasma {
        text = glassScheme;
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
    text = opaqueScheme + "\n[Icons]\nTheme=${theme.icons}\n";
  };

  # Each session applies its own scheme and Qt style at login, because both
  # sessions read the same kdeglobals. The Plasma look names them.
  systemd.user.services.oruc-plasma-colors = lib.mkIf isPlasma {
    Unit = {
      Description = "Apply the color scheme and Qt style of the Plasma look";
      # Only a Plasma session reaches plasma-workspace.target.
      After = [
        "plasma-workspace.target"
        "plasma-plasmashell.service"
      ];
      PartOf = [ "plasma-workspace.target" ];
      # Stop retrying when Plasma keeps rejecting the scheme. A skipped start
      # counts too, and a deploy with a stored Plasma look starts the unit
      # twice, so the limit leaves room for a plasma-look right after it.
      StartLimitIntervalSec = 60;
      StartLimitBurst = 5;
    };
    Service = {
      Type = "oneshot";
      ExecCondition = colorsOnce.condition;
      ExecStart = "${applyColorScheme} ${config.oruc.plasma.colorScheme}";
      # The niri session reads the same kdeglobals, so it needs the icon theme too.
      ExecStartPost = [
        (setWidgetStyle config.oruc.plasma.widgetStyle)
      ]
      ++ lib.optional isNiri iconTheme
      ++ [ colorsOnce.mark ];
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "plasma-workspace.target" ];
  };

  # niri blurs only the windows that niri/config.kdl lists, so its sessions
  # put back the opaque scheme and Breeze.
  systemd.user.services.oruc-niri-colors = lib.mkIf (isPlasma && isNiri) {
    Unit = {
      Description = "Apply the opaque Base16 color scheme and the Breeze style";
      After = [ "niri.service" ];
      PartOf = [ "niri.service" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${applyColorScheme} OrucBase16";
      ExecStartPost = setWidgetStyle "Breeze";
    };
    Install.WantedBy = [ "niri.service" ];
  };
}
