{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  scheme = osConfig.scheme.withHashtag;

  batPreview = "bat --color=always --style=numbers --line-range=:200 {}";
  treePreview = "eza --tree --level=2 --color=always --icons=always {}";
  # fzf's default walker for Ctrl-T lists directories as well as files.
  pathPreview = "if [ -d {} ]; then ${treePreview}; else ${batPreview}; fi";
  previewWindow = "--preview-window=right:50%:wrap";

  # Commands that print or set a secret stay out of both histories. Atuin
  # takes regexes, zsh's HISTORY_IGNORE glob patterns of the whole line.
  secretCommands = [
    "gh auth token"
    "secret-tool lookup"
    "pass show"
    "pass grep"
    "infisical secrets get"
  ];
  secretVariables = [
    "AWS_SECRET_ACCESS_KEY"
    "AWS_SESSION_TOKEN"
    "GITHUB_TOKEN"
    "GH_TOKEN"
    "NPM_TOKEN"
    "INFISICAL_TOKEN"
  ];
in
{
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    # zsh-patina highlights instead; see initContent.
    syntaxHighlighting.enable = false;
    autocd = true;
    setOptions = [
      "CORRECT"
      "AUTO_PUSHD"
    ];
    # CORRECT would otherwise offer completion functions such as _cowsay for a
    # command that is not installed.
    localVariables.CORRECT_IGNORE = "_*";
    history = {
      size = 100000;
      save = 100000;
      extended = true;
      ignoreDups = true;
      share = true;
      ignorePatterns =
        lib.concatMap (command: [
          command
          "${command} *"
        ]) secretCommands
        ++ lib.concatMap (variable: [
          "${variable}=*"
          "export ${variable}=*"
        ]) secretVariables
        ++ [
          "*[Aa]uthorization:*"
          "*--cookie[ =]*"
        ];
    };
    oh-my-zsh = {
      enable = true;
      plugins = [
        "colored-man-pages"
        "git"
        "sudo"
      ];
    };
    # Up and Down stay with Atuin; Ctrl-P and Ctrl-N are bound below.
    historySubstringSearch = {
      enable = true;
      searchUpKey = [ ];
      searchDownKey = [ ];
    };
    plugins = [
      {
        name = "fzf-tab";
        src = pkgs.zsh-fzf-tab;
        file = "share/fzf-tab/fzf-tab.plugin.zsh";
      }
    ];
    shellAliases = {
      ll = "eza -la";
      la = "eza -a";
      l = "eza -F";
      "..." = "cd ../..";
      "...." = "cd ../../..";
      mkdir = "mkdir -pv";
      wget = "wget -c";
    };
    initContent = lib.mkMerge [
      (lib.mkOrder 500 ''
        export PATH="$HOME/.local/bin:$HOME/go/bin:$HOME/.cargo/bin:$PATH"
        zstyle ':omz:update' mode disabled

        # Keep fzf's file and directory widgets, but leave Ctrl-R to Atuin.
        eval "$(${lib.getExe config.programs.fzf.package} --zsh)"
        bindkey -r '^R'
      '')
      (lib.mkOrder 2000 ''
        # Agent-launched interactive shells do not enter commands into Atuin.
        # Native Zsh history stays active in every shell as a fallback.
        if [[ -z "''${CLAUDECODE:-}" \
           && -z "''${CLAUDE_CODE_NEW_INIT:-}" \
           && -z "''${CODEX_SESSION_ID:-}" \
           && -z "''${CODEX_THREAD_ID:-}" \
           && -z "''${OPENCODE_DB:-}" \
           && -z "''${CURSOR_AGENT:-}" \
           && -z "''${GROK_SESSION_ID:-}" ]]; then
          eval "$(${lib.getExe config.programs.atuin.package} init zsh)"
        fi

        # Atuin keeps Up and Ctrl-R. Ctrl-P and Ctrl-N search the history for
        # the text typed so far, and step through it when the line is empty.
        # Oh My Zsh makes emacs the main keymap; viins covers a switch to vi mode.
        for keymap in emacs viins; do
          bindkey -M "$keymap" '^P' history-substring-search-up
          bindkey -M "$keymap" '^N' history-substring-search-down
        done
      '')
      # Last, so the highlighter wraps every widget defined before it.
      (lib.mkOrder 2500 ''
        eval "$(${lib.getExe pkgs.zsh-patina} activate)"
      '')
    ];
  };

  programs.atuin = {
    enable = true;
    enableZshIntegration = false;
    forceOverwriteSettings = false;
    settings = {
      auto_sync = false;
      update_check = false;
      store_failed = true;
      secrets_filter = true;
      workspaces = true;
      search_mode = lib.mkDefault "fuzzy";
      filter_mode = "workspace";
      search_mode_shell_up_key_binding = lib.mkDefault "fuzzy";
      filter_mode_shell_up_key_binding = "workspace";
      search.filters = [
        "workspace"
        "directory"
        "host"
        "session"
        "global"
      ];
      # At the default of 0 the search fills the screen and pins a short
      # result list to the bottom, far below the prompt.
      inline_height = 20;
      tmux = {
        enabled = true;
        width = "80%";
        height = "60%";
      };
      daemon.autostart = false;
      history_filter =
        map (
          command: "^[[:space:]]*${lib.replaceStrings [ " " ] [ "[[:space:]]+" ] command}([[:space:]]|$)"
        ) secretCommands
        ++ [
          "^[[:space:]]*(export[[:space:]]+)?(${lib.concatStringsSep "|" secretVariables})="
          "(?i)authorization:"
          "--cookie[[:space:]=]"
        ];
    };
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = false;
    defaultCommand = "${lib.getExe pkgs.fd} --type f --hidden --exclude .git";
    defaultOptions = [
      "--height=40%"
      "--layout=reverse"
      "--border=rounded"
    ];
    # Slots as in the tinted-theming fzf template.
    colors = {
      "bg+" = scheme.base01;
      bg = scheme.base00;
      spinner = scheme.base0C;
      hl = scheme.base0D;
      fg = scheme.base04;
      header = scheme.base0D;
      info = scheme.base0A;
      pointer = scheme.base0C;
      marker = scheme.base0C;
      "fg+" = scheme.base06;
      prompt = scheme.base0A;
      "hl+" = scheme.base0D;
    };
    fileWidget.options = [
      "--preview '${pathPreview}'"
      previewWindow
    ];
    changeDirWidget.options = [
      "--preview '${treePreview}'"
      previewWindow
    ];
  };

  # The base16 theme uses the terminal's ANSI colors, which come from the scheme.
  programs.bat = {
    enable = true;
    config.theme = "base16";
  };
  programs.zoxide = {
    enable = true;
    enableZshIntegration = true;
  };
  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
  };
  programs.eza.enable = true;
  programs.nix-index = {
    enable = true;
    enableZshIntegration = true;
  };
  # nix-index-database supplies the database, and comma runs a missing
  # command from it.
  programs.nix-index-database.comma.enable = true;

  programs.starship = {
    enable = true;
    enableZshIntegration = true;
  };
  xdg.configFile."starship.toml".source = ../starship.toml;
}
