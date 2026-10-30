{
  agents,
  config,
  inputs,
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  hasDesktop = sessions.hasAnyDesktop osConfig.oruc.machine;
  hasScreen = sessions.hasGraphicalUser osConfig.oruc.machine;
  # Brave keeps the key that encrypts its cookies and passwords in KWallet
  # under Plasma and in the Secret Service under niri, and neither session
  # can read the other's. On a machine with Plasma it uses KWallet in every
  # session; niri-session.nix opens the wallet at a niri login.
  #
  # On nixos-rog's Radeon 890M, a WebRTC receiver decodes none of the frames
  # that Brave's VA-API H.264 encoder sends, and logs that no PPS arrived, so a
  # screen share to Teams arrives black or frozen. Turning the encoder off
  # makes WebRTC use OpenH264. Chromium keeps only the last --disable-features, so the list
  # repeats the two features the package disables, and a disabled feature wins
  # over the package's --enable-features.
  braveArgs =
    lib.optional (sessions.hasDesktop osConfig.oruc.machine "plasma") "--password-store=kwallet6"
    ++ lib.optional (osConfig.oruc.machine.gpu == "hybrid") (
      "--disable-features="
      + lib.concatStringsSep "," [
        "OutdatedBuildDetector"
        "UseChromeOSDirectVideoDecoder"
        "AcceleratedVideoEncoder"
      ]
    );
  # Brave Origin 1.98.60 moves to Chromium 156 for its security fixes, and
  # nixpkgs still builds 1.97.59. Remove the override once nixpkgs has 1.98.60.
  braveOrigin =
    if lib.versionOlder pkgs.brave-origin.version "1.98.60" then
      pkgs.brave-origin.overrideAttrs (
        finalAttrs: _: {
          version = "1.98.60";
          src = pkgs.fetchurl {
            url = "https://github.com/brave/brave-browser/releases/download/v${finalAttrs.version}/brave-origin_${finalAttrs.version}_amd64.deb";
            hash = "sha256-VKBbHBK684D7dwqyhhwh87uQJfU3VQ9tNEHxre9S5jk=";
          };
        }
      )
    else
      pkgs.brave-origin;
  brave =
    if braveArgs == [ ] then
      braveOrigin
    else
      braveOrigin.override { commandLineArgs = lib.concatStringsSep " " braveArgs; };
  # legacyPackages refuses the unfree google-chrome, so import the pinned nixpkgs.
  securityPkgs = import inputs.nixpkgs-security {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  chrome =
    if lib.versionOlder pkgs.google-chrome.version securityPkgs.google-chrome.version then
      securityPkgs.google-chrome
    else
      pkgs.google-chrome;
  releaseAgeDays = 3;
  opencode = pkgs.symlinkJoin {
    name = "opencode-${agents.opencode2.version}";
    paths = [ agents.opencode2 ];
    postBuild = "ln -s opencode2 $out/bin/opencode";
  };
  # grok copies through the Wayland clipboard and also through OSC 52. Ghostty's
  # OSC 52 claim loses that race, and GTK then shows Ghostty an empty clipboard,
  # so Ctrl+Shift+V types ESC[118;6u. Over SSH, OSC 52 is the only route home.
  grok = pkgs.symlinkJoin {
    name = "grok-${agents.grok.version}";
    paths = [ agents.grok ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/grok \
        --run 'if [ -z "''${SSH_CONNECTION:-}" ]; then export GROK_CLIPBOARD_NO_OSC52=1; fi'
    '';
  };
  # Ghostty hands a clicked ~/ path to xdg-open as written, and xdg-utils does
  # not expand the tilde: https://github.com/ghostty-org/ghostty/pull/5813
  xdgOpen = pkgs.writeShellApplication {
    name = "xdg-open";
    text = ''
      if [[ $# -eq 1 && ''${HOME:-} == /* ]]; then
        case $1 in
          \~ | \~/*) set -- "$HOME''${1#\~}" ;;
        esac
      fi
      exec ${lib.getExe' pkgs.xdg-utils "xdg-open"} "$@"
    '';
  };
  # Skipped without a graphical user. They stay in the list below, and the list
  # is filtered, so that the order of the packages on a desktop stays as it is.
  desktopPackages = [
    pkgs.firefox
    pkgs.nerd-fonts.caskaydia-cove
    pkgs.sourcegit
    brave
    chrome
  ];
in
{
  home.packages = lib.subtractLists (lib.optionals (!hasScreen) desktopPackages) (
    with pkgs;
    [
      # keep-sorted start
      cloudflared
      curl
      fd
      file
      firefox
      gitleaks
      infisical
      jq
      mcp-nixos
      nerd-fonts.caskaydia-cove
      nix-search-tv
      nixfmt
      pipx
      ripgrep
      sourcegit
      tree
      unzip
      wget
      yq-go
      zip
      # keep-sorted end
    ]
    ++ (with agents; [
      # keep-sorted start
      agentsview
      codex
      cursor-agent
      herdr
      # keep-sorted end
    ])
    ++ [
      brave
      chrome
      grok
      opencode
    ]
    ++ lib.optional hasDesktop xdgOpen
  );

  programs.mcp = {
    enable = true;
    servers.nixos.command = lib.getExe pkgs.mcp-nixos;
  };
  # With preferXdgDirectories and stateVersion 26.11, Home Manager moves the
  # config to ~/.config/claude and exports CLAUDE_CONFIG_DIR there, which hides
  # every session, login and setting kept in ~/.claude.
  programs.claude-code = {
    enable = true;
    package = agents.claude-code;
    configDir = "${config.home.homeDirectory}/.claude";
    enableMcpIntegration = true;
  };

  programs.uv = {
    enable = true;
    settings = {
      exclude-newer = "${toString releaseAgeDays} days";
      # uv's bundled CA roots lag the system store in removing distrusted roots.
      system-certs = true;
    };
  };
  programs.npm = {
    enable = true;
    package = null;
    settings = {
      min-release-age = releaseAgeDays;
      cache = "${config.xdg.cacheHome}/npm";
    };
  };
  programs.bun = {
    enable = true;
    package = null;
    # Its git integration needs the bun package.
    enableGitIntegration = false;
    settings.install.minimumReleaseAge = releaseAgeDays * 86400;
  };

  programs.btop = {
    enable = true;
    settings = {
      color_theme = "TTY";
      theme_background = false;
    };
  };

  oruc.variantReloads.ghostty = lib.mkIf config.programs.ghostty.enable ''pkill -USR2 -u "$(id -u)" -f "^${config.programs.ghostty.package}/bin/ghostty" || true'';

  programs.ghostty = lib.mkIf hasDesktop {
    enable = true;
    enableZshIntegration = true;
    settings = {
      font-family = "CaskaydiaCove Nerd Font Mono";
      font-size = 13;
      font-feature = [
        "-calt"
        "-liga"
        "-dlig"
      ];
      font-shaping-break = "cursor";
      background-opacity = lib.mkDefault 0.9;
      background-blur = true;
      notify-on-command-finish = "unfocused";
      notify-on-command-finish-action = "notify";
      notify-on-command-finish-after = "10s";
      window-padding-x = lib.mkDefault 6;
      window-padding-y = lib.mkDefault 4;
      window-padding-balance = true;
      window-padding-color = "extend";
      window-decoration = "server";
      window-theme = "auto";
      window-inherit-working-directory = true;
      tab-inherit-working-directory = true;
      window-inherit-font-size = true;
      window-show-tab-bar = "auto";
      scrollback-limit = 100000000;
      cursor-style = "bar";
      cursor-style-blink = true;
      copy-on-select = "clipboard";
      mouse-shift-capture = false;
      clipboard-read = "allow";
      clipboard-write = "allow";
      clipboard-trim-trailing-spaces = true;
      clipboard-paste-bracketed-safe = false;
      clipboard-paste-protection = false;
      shell-integration = "detect";
      shell-integration-features = "ssh-env";
      unfocused-split-opacity = 0.85;
      alpha-blending = "linear-corrected";
      bold-is-bright = true;
      window-vsync = true;
      confirm-close-surface = true;
      resize-overlay = "always";
      # io_uring rings count against the per-user memlock limit. When it is
      # full, new tabs stay blank (error.SystemResources); epoll uses no rings.
      async-backend = "epoll";
      # Only binds that differ from Ghostty's defaults. ctrl+equal and ctrl+minus
      # are separate triggers from the default ctrl+= and ctrl+-, so they stay.
      keybind = [
        "ctrl+shift+c=copy_to_clipboard"
        "ctrl+shift+w=close_surface"
        "ctrl+shift+f=toggle_fullscreen"
        "ctrl+shift+r=reload_config"
        "ctrl+shift+left_bracket=new_split:left"
        "ctrl+shift+right_bracket=new_split:down"
        "ctrl+shift+left=goto_split:left"
        "ctrl+shift+right=goto_split:right"
        "ctrl+shift+up=goto_split:top"
        "ctrl+shift+down=goto_split:bottom"
        "ctrl+equal=increase_font_size:1"
        "ctrl+minus=decrease_font_size:1"
      ];
    };
  };

  xdg.configFile = {
    # pnpm reads this setting only from its global config.yaml, not from rc.
    "pnpm/config.yaml".text = ''
      minimumReleaseAge: ${toString (releaseAgeDays * 1440)}
    '';
  };

  programs.tmux = {
    enable = true;
    baseIndex = 1;
    clock24 = true;
    escapeTime = 0;
    historyLimit = 100000;
    keyMode = "vi";
    mouse = true;
    terminal = "tmux-256color";
    plugins = [ pkgs.tmuxPlugins.vim-tmux-navigator ];
    extraConfig = ''
      set -g renumber-windows on
      set -ga terminal-overrides ",xterm-256color:Tc"
    '';
  };

  xdg.mimeApps = lib.mkIf hasScreen {
    enable = true;
    defaultApplications = {
      "text/html" = [ "brave-origin.desktop" ];
      "x-scheme-handler/http" = [ "brave-origin.desktop" ];
      "x-scheme-handler/https" = [ "brave-origin.desktop" ];
      "application/pdf" = [ "brave-origin.desktop" ];
      "x-scheme-handler/claude-cli" = [ "claude-code-url-handler.desktop" ];
    };
  };
  # Apps that register their own URL scheme rewrite mimeapps.list. Every such
  # scheme is declared, so the next switch replaces the file without a backup.
  xdg.configFile."mimeapps.list" = lib.mkIf hasScreen { force = true; };

  home.sessionVariables =
    lib.optionalAttrs hasScreen { BROWSER = "brave-origin"; }
    // lib.optionalAttrs hasDesktop { TERMINAL = "ghostty"; };
}
