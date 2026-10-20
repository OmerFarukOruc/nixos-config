{
  agents,
  config,
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
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
  brave =
    if braveArgs == [ ] then
      pkgs.brave-origin
    else
      pkgs.brave-origin.override { commandLineArgs = lib.concatStringsSep " " braveArgs; };
  # Days a release must age before a package manager installs it.
  releaseAgeDays = 3;
  # OpenCode 2 from llm-agents installs as opencode2, beside version 1. It is
  # the only OpenCode here, so it also answers to opencode, as on fedora-desktop.
  opencode = pkgs.symlinkJoin {
    name = "opencode-${agents.opencode2.version}";
    paths = [ agents.opencode2 ];
    postBuild = "ln -s opencode2 $out/bin/opencode";
  };
in
{
  home.packages =
    with pkgs;
    [
      # keep-sorted start
      cloudflared
      curl
      fd
      file
      firefox
      gitleaks
      google-chrome
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
    # Interactive coding agents used directly on this host.
    ++ (with agents; [
      # keep-sorted start
      agentsview
      codex
      cursor-agent
      grok
      herdr
      # keep-sorted end
    ])
    ++ [
      brave
      opencode
    ];

  # Claude Code gets the NixOS MCP server, so it looks up option and package
  # names instead of guessing them. Home Manager delivers the server list as
  # a plugin in ~/.claude/skills/claude-code-home-manager; desktop/bin/desktop-sync.sh
  # in the dotfiles checkout (docs/nixos-rog.md, Claude Code and Codex setup)
  # links the other entries there and removes only dangling ones.
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

  # Package managers install only releases that have aged releaseAgeDays, so a
  # hijacked release is usually pulled before it reaches this host. Each tool
  # takes its own unit. npm, bun and pnpm come from project shells, so only
  # their config is installed here; pnpm's is with xdg.configFile below.
  programs.uv = {
    enable = true;
    settings.exclude-newer = "${toString releaseAgeDays} days";
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

  # The TTY theme follows the terminal's 16 ANSI colors, which come from the scheme.
  programs.btop = {
    enable = true;
    settings = {
      color_theme = "TTY";
      theme_background = false;
    };
  };

  programs.ghostty = {
    enable = true;
    enableZshIntegration = true;
    settings = {
      # The family matches fedora-desktop. The bars use oruc.theme.fonts.mono instead.
      font-family = "CaskaydiaCove Nerd Font Mono";
      font-size = 13;
      font-feature = [
        "-calt"
        "-liga"
        "-dlig"
      ];
      font-shaping-break = "cursor";
      # At 0.65 a white window behind turned the background mid-gray, and the
      # text fell to 3:1 contrast. At 0.90 the base04 gray keeps 5:1. The Glass
      # look sets 0.66; its contrast over a white window is not measured.
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
      # Sets TERM to xterm-256color on ssh, so remote hosts without Ghostty's
      # terminfo still render.
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
    # Ctrl-h/j/k/l cross tmux panes and Neovim splits; the Neovim side needs
    # the matching vim-tmux-navigator plugin.
    plugins = [ pkgs.tmuxPlugins.vim-tmux-navigator ];
    extraConfig = ''
      set -g renumber-windows on
      set -ga terminal-overrides ",xterm-256color:Tc"
    '';
  };

  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "text/html" = [ "brave-origin.desktop" ];
      "x-scheme-handler/http" = [ "brave-origin.desktop" ];
      "x-scheme-handler/https" = [ "brave-origin.desktop" ];
      "application/pdf" = [ "brave-origin.desktop" ];
      # Claude Code writes this handler file itself and registers it again with
      # xdg-mime, which replaces the Home Manager link with a plain file.
      "x-scheme-handler/claude-cli" = [ "claude-code-url-handler.desktop" ];
    };
  };
  # Apps that register their own URL scheme rewrite mimeapps.list. Every such
  # scheme is declared, so the next switch replaces the file without a backup.
  xdg.configFile."mimeapps.list".force = true;

  home.sessionVariables = {
    BROWSER = "brave-origin";
    TERMINAL = "ghostty";
  };
}
