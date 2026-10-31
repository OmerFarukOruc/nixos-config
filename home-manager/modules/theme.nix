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
  theme = config.oruc.theme;
  isPlasma = sessions.hasDesktop cfg "plasma";
  isNiri = sessions.hasDesktop cfg "niri";
  hasDesktop = sessions.hasAnyDesktop cfg;
  hasFonts = sessions.hasGraphicalUser cfg;

  warmBurnout = import ./warm-burnout.nix { inherit inputs pkgs; };

  kdeColorScheme =
    scheme:
    import ./plasma-looks/kde-color-scheme.nix {
      inherit lib;
      rawScheme = scheme;
    };
  kwriteconfig = lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6";
  setWidgetStyle = style: "${kwriteconfig} --file kdeglobals --group KDE --key widgetStyle ${style}";

  loginUnits = {
    oruc-plasma-colors = "plasma-workspace.target";
  }
  // lib.optionalAttrs isNiri { oruc-niri-colors = "niri.service"; };
  oncePerLogin = lib.mapAttrs (
    name: target:
    import ./plasma-looks/once-per-login.nix { inherit lib pkgs; } { inherit name target; }
  ) loginUnits;

  slots = map (n: "base0${n}") (lib.stringToCharacters "0123456789ABCDEF");
  nvimTheme = "${config.xdg.configHome}/oruc/nvim-theme.lua";
  tmuxTheme = "${config.xdg.configHome}/tmux/oruc-theme.conf";
  tmux = lib.getExe config.programs.tmux.package;
  nvim = lib.getExe config.programs.nvf.finalPackage;
in
{
  fonts.fontconfig.enable = hasFonts;

  home.packages = lib.optionals hasFonts (
    with pkgs;
    [
      inter
      nerd-fonts.jetbrains-mono
      noto-fonts
      noto-fonts-color-emoji
    ]
  );

  programs.ghostty.settings.config-file = "?oruc-colors";

  programs.tmux.extraConfig = ''
    source-file -q ${tmuxTheme}
  '';

  oruc.vscodeSettings."terminal.integrated.minimumContrastRatio" = 1;

  programs.atuin.settings.theme.name = "Oruc Base16";

  oruc.themeFiles = lib.mkMerge [
    {
      ".config/oruc/nvim-theme.lua" =
        { scheme, theme }:
        if theme.warmBurnout then
          "vim.cmd.colorscheme('${scheme.scheme-slug}')"
        else
          "require('base16-colorscheme').setup({ ${
            lib.concatMapStringsSep ", " (slot: "${slot} = '${scheme.withHashtag.${slot}}'") slots
          } })";
    }
    (lib.mkIf config.programs.ghostty.enable {
      ".config/ghostty/oruc-colors" =
        { scheme, theme }:
        lib.concatLines (
          lib.imap0 (index: slot: "palette = ${toString index}=${scheme.withHashtag.${slot}}") theme.ansi
          ++ [
            "background = ${scheme.base00}"
            "foreground = ${scheme.base05}"
            "cursor-color = ${scheme.base05}"
            "selection-background = ${scheme.base02}"
            "selection-foreground = ${scheme.base05}"
          ]
        );
    })
    (lib.mkIf config.programs.tmux.enable {
      ".config/tmux/oruc-theme.conf" =
        { scheme, ... }:
        let
          s = scheme.withHashtag;
        in
        ''
          set -g status-style "fg=${s.base05},bg=${s.base01}"
          set -g window-status-style "fg=${s.base04}"
          set -g window-status-current-style "fg=${s.base00},bg=${s.base0D},bold"
          set -g message-style "fg=${s.base05},bg=${s.base02}"
          set -g mode-style "fg=${s.base05},bg=${s.base02}"
          set -g pane-border-style "fg=${s.base02}"
          set -g pane-active-border-style "fg=${s.base0D}"
        '';
    })
    (lib.mkIf isPlasma {
      ".local/share/oruc/kde/OrucBase16.colors" = { scheme, ... }: kdeColorScheme scheme false;
      ".local/share/oruc/kde/OrucBase16Glass.colors" = { scheme, ... }: kdeColorScheme scheme true;
    })
    (lib.mkIf (isNiri && !isPlasma) {
      ".config/kdeglobals" =
        { scheme, theme }: kdeColorScheme scheme false + "\n[Icons]\nTheme=${theme.icons}\n";
    })
    (lib.mkIf config.programs.atuin.enable {
      ".config/atuin/themes/oruc-base16.toml" =
        { scheme, ... }:
        lib.concatLines (
          [ "[colors]" ]
          ++ lib.mapAttrsToList (name: slot: "${name} = \"${scheme.withHashtag.${slot}}\"") {
            Base = "base05";
            Title = "base0D";
            Important = "base08";
            Guidance = "base04";
            Annotation = "base03";
            AlertInfo = "base0C";
            AlertWarn = "base0A";
            AlertError = "base08";
          }
          ++ [
            ""
            "[theme]"
            "name = \"Oruc Base16\""
          ]
        );
    })
  ];

  oruc.variantReloads = lib.mkMerge [
    (lib.mkIf config.programs.tmux.enable {
      tmux = ''
        status=0
        for socket in "''${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"/*; do
          [[ -S $socket ]] || continue
          ${tmux} -S "$socket" list-sessions >/dev/null 2>&1 || continue
          ${tmux} -S "$socket" source-file -q ${tmuxTheme} || status=1
        done
        exit "$status"
      '';
    })
    (lib.mkIf config.programs.nvf.enable {
      neovim = ''
        status=0
        for server in "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/${config.programs.nvf.settings.vim.appname}.*.0; do
          [[ -S $server ]] || continue
          timeout 2 ${nvim} --server "$server" --remote-expr 1 >/dev/null 2>&1 || continue
          timeout 5 ${nvim} --server "$server" --remote-expr "execute('luafile ${nvimTheme}')" >/dev/null || status=1
        done
        exit "$status"
      '';
    })
  ];

  programs.nvf.settings.vim = {
    startPlugins = [ "base16" ];
    extraPlugins.oruc-theme = {
      package = warmBurnout.nvim;
      setup = ''
        local ok, err = pcall(dofile, ${builtins.toJSON nvimTheme})
        if not ok then vim.notify(err, vim.log.levels.WARN) end
      '';
    };
  };

  xdg.dataFile = {
    # An attribute name cannot carry the store path's context.
    "backgrounds/oruc/${builtins.unsafeDiscardStringContext (builtins.baseNameOf theme.wallpaper)}" =
      lib.mkIf hasDesktop
        { source = theme.wallpaper; };
    # Plasma's translucent desktop theme has no colors file of its own, and
    # looking one up on every menu and popup slows them down. Plasma only
    # checks that the file exists and never reads it; the colours come from
    # kdeglobals.
    "plasma/desktoptheme/default/translucent/colors" = lib.mkIf isPlasma {
      text = "";
    };
  };

  home.activation.markLogins = lib.mkIf isPlasma (
    lib.hm.dag.entryBefore [ "reloadSystemd" ] ''
      if [[ ! -v DRY_RUN ]]; then
        runtime=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
        ${lib.concatMapAttrsStringSep "\n" (
          _: once: "XDG_RUNTIME_DIR=$runtime ${once.markIn "$runtime"} 2>/dev/null || true"
        ) oncePerLogin}
        unset runtime
      fi
    ''
  );

  systemd.user.services.oruc-plasma-colors = lib.mkIf isPlasma {
    Unit = {
      Description = "Apply the color scheme and Qt style of the Plasma look";
      After = [
        "plasma-workspace.target"
        "plasma-plasmashell.service"
      ];
      PartOf = [ "plasma-workspace.target" ];
      StartLimitIntervalSec = 60;
      StartLimitBurst = 5;
    };
    Service = {
      Type = "oneshot";
      ExecCondition = oncePerLogin.oruc-plasma-colors.condition;
      ExecStart = "${lib.getExe config.oruc.plasma.live} --login ${config.oruc.plasma.look}";
      ExecStartPost = [
        (setWidgetStyle config.oruc.plasma.widgetStyle)
        oncePerLogin.oruc-plasma-colors.mark
      ];
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "plasma-workspace.target" ];
  };

  systemd.user.services.oruc-niri-colors = lib.mkIf (isPlasma && isNiri) {
    Unit = {
      Description = "Apply the opaque Base16 color scheme and the Breeze style";
      After = [ "niri.service" ];
      PartOf = [ "niri.service" ];
    };
    Service = {
      Type = "oneshot";
      ExecCondition = oncePerLogin.oruc-niri-colors.condition;
      ExecStart = "${lib.getExe config.oruc.plasma.kdeColors} OrucBase16";
      ExecStartPost = [
        (setWidgetStyle "Breeze")
        oncePerLogin.oruc-niri-colors.mark
      ];
    };
    Install.WantedBy = [ "niri.service" ];
  };
}
