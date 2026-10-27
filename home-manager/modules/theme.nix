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
  rawScheme = config.scheme;
  scheme = config.scheme.withHashtag;
  theme = config.oruc.theme;
  isPlasma = sessions.hasDesktop cfg "plasma";
  isNiri = sessions.hasDesktop cfg "niri";
  hasDesktop = sessions.hasAnyDesktop cfg;

  # A warm-burnout-* scheme brings Warm Burnout's own VS Code and Neovim
  # themes, which color syntax beyond the 16 Base16 slots.
  isWarmBurnout = lib.hasPrefix "warm-burnout-" config.oruc.scheme;
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

  # Every other scheme gets the whole VS Code theme that tinted-vscode's
  # template renders from it. The template is rendered in a build, so the
  # evaluation reads nothing from it. VS Code finds the extension through a
  # link that Home Manager writes, so a `theme` switch needs no new VS Code
  # package.
  tintedThemeLabel = "Base16 ${rawScheme.scheme-name}";
  tintedVscode = pkgs.vscode-utils.buildVscodeExtension {
    pname = "oruc-base16-theme";
    version = "1.0.0";
    vscodeExtPublisher = "oruc";
    vscodeExtName = "base16-theme";
    vscodeExtUniqueId = "oruc.base16-theme";
    dontUnpack = true;
    installPhase = ''
      mkdir -p "$out/$installPrefix/themes"
      cp ${
        pkgs.writeText "package.json" (
          builtins.toJSON {
            name = "base16-theme";
            publisher = "oruc";
            version = "1.0.0";
            engines.vscode = "^1.85.0";
            contributes.themes = [
              {
                label = tintedThemeLabel;
                uiTheme = if theme.isLight then "vs" else "vs-dark";
                path = "./themes/base16.json";
              }
            ];
          }
        )
      } "$out/$installPrefix/package.json"
      cp ${
        config.scheme {
          templateRepo = inputs.tinted-vscode;
          target = "base16";
        }
      } "$out/$installPrefix/themes/base16.json"
    '';
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

  kdeColorScheme = import ./plasma-looks/kde-color-scheme.nix { inherit lib rawScheme; };
  opaqueScheme = kdeColorScheme false;
  applyColorScheme = lib.getExe' pkgs.kdePackages.plasma-workspace "plasma-apply-colorscheme";
  kwriteconfig = lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6";
  setWidgetStyle = style: "${kwriteconfig} --file kdeglobals --group KDE --key widgetStyle ${style}";
  iconTheme = "${kwriteconfig} --file kdeglobals --group Icons --key Theme ${theme.icons}";

  colorsOnce = import ./plasma-looks/once-per-login.nix { inherit lib pkgs; } "oruc-plasma-colors";
in
{
  fonts.fontconfig.enable = hasDesktop;

  # These packages provide the families named by oruc.theme.fonts.
  home.packages = lib.optionals hasDesktop (
    with pkgs;
    [
      inter
      nerd-fonts.jetbrains-mono
      noto-fonts
      noto-fonts-color-emoji
    ]
  );

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
      if isWarmBurnout then "Warm Burnout ${lib.toSentenceCase warmBurnoutVariant}" else tintedThemeLabel;
    # vscode.nix sets the see-through backgrounds. The terminal takes
    # Ghostty's colors.
    "workbench.colorCustomizations" = {
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

  programs.vscode.profiles.default.extensions = [
    (if isWarmBurnout then warmBurnoutVscode else tintedVscode)
  ];

  # Neovim loads its colors from a file, because `theme` switches the scheme
  # without a new Neovim package (variants.nix). Both color schemes are installed.
  xdg.configFile."oruc/nvim-theme.lua".text =
    if isWarmBurnout then
      "vim.cmd.colorscheme('warm-burnout-${warmBurnoutVariant}')"
    else
      "require('base16-colorscheme').setup({ ${
        lib.concatMapStringsSep ", " (slot: "${slot} = '${scheme.${slot}}'") (
          map (n: "base0${n}") (lib.stringToCharacters "0123456789ABCDEF")
        )
      } })";

  programs.nvf.settings.vim = {
    # nvf's own base16 plugin, which its base16 theme would start.
    startPlugins = [ "base16" ];
    extraPlugins.oruc-theme = {
      package = warmBurnoutNvim;
      setup = ''
        local ok, err = pcall(dofile, ${builtins.toJSON "${config.xdg.configHome}/oruc/nvim-theme.lua"})
        if not ok then vim.notify(err, vim.log.levels.WARN) end
      '';
    };
  };

  xdg.dataFile = {
    # An attribute name cannot carry the store path's context.
    "backgrounds/oruc/${builtins.unsafeDiscardStringContext (builtins.baseNameOf theme.wallpaper)}" =
      lib.mkIf hasDesktop
        { source = theme.wallpaper; };
    "color-schemes/OrucBase16.colors" = lib.mkIf (isPlasma || isNiri) {
      text = opaqueScheme;
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
