{
  config,
  lib,
  pkgs,
  ...
}:
let
  scheme = config.scheme.withHashtag;

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
  # root imports this file alone, so it brings the scheme along.
  imports = [ ./scheme.nix ];

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
    # Up and Down search the history for the text typed so far. Ctrl-P and
    # Ctrl-N are bound below; Atuin keeps Ctrl-R.
    historySubstringSearch = {
      enable = true;
      searchUpKey = [
        "^[[A"
        "^[OA"
      ];
      searchDownKey = [
        "^[[B"
        "^[OB"
      ];
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
    # Claude Code and Codex run each command as `zsh -c`, which reads .zshenv
    # but not .zshrc, and set CLAUDECODE or CODEX_THREAD_ID. In those shells an
    # unmatched glob stays as text instead of aborting the command, and a word
    # that starts with = stays as text instead of a path. A script file, and a
    # shell a person types in, keep zsh's defaults.
    envExtra = ''
      if [[ -n $ZSH_EXECUTION_STRING && ( -n $CLAUDECODE || -n $CODEX_THREAD_ID ) ]]; then
        setopt nonomatch noequals
      fi
    '';
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
          eval "$(${lib.getExe config.programs.atuin.package} init zsh --disable-up-arrow)"
        fi

        # Ctrl-P and Ctrl-N search the history like Up and Down, and step
        # through it when the line is empty.
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

  home.sessionVariables.FZF_DEFAULT_OPTS_FILE = "${config.xdg.configHome}/fzf/fzfrc";
  # Colors in the slots of the tinted-theming fzf template.
  xdg.configFile."fzf/fzfrc".text = lib.concatStringsSep "\n" [
    "--height=40%"
    "--layout=reverse"
    "--border=rounded"
    "--color=${
      lib.concatStringsSep "," (
        lib.mapAttrsToList (name: slot: "${name}:${scheme.${slot}}") {
          "bg+" = "base01";
          bg = "base00";
          spinner = "base0C";
          hl = "base0D";
          fg = "base04";
          header = "base0D";
          info = "base0A";
          pointer = "base0C";
          marker = "base0C";
          "fg+" = "base06";
          prompt = "base0A";
          "hl+" = "base0D";
        }
      )
    }"
  ];

  programs.fzf = {
    enable = true;
    enableZshIntegration = false;
    defaultCommand = "${lib.getExe pkgs.fd} --type f --hidden --exclude .git";
    # The options live in a file, because `theme` switches the colors without
    # a new session-variables package (variants.nix).
    defaultOptions = [ ];
    colors = { };
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
    options = [
      "--cmd"
      "cd"
    ];
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
  # Starship reads its config at each prompt, so `theme` recolors open shells.
  # The surfaces blend base00 toward base05, because schemes disagree on
  # whether base01 is lighter or darker than base00.
  xdg.configFile."starship.toml".text =
    let
      slot =
        name:
        map (c: lib.toInt config.scheme."${name}-rgb-${c}") [
          "r"
          "g"
          "b"
        ];
      surface =
        percent:
        lib.zipListsWith (bg: fg: (bg * (100 - percent) + fg * percent) / 100) (slot "base00") (
          slot "base05"
        );
      hex = color: "#" + lib.concatMapStrings (c: lib.fixedWidthString 2 "0" (lib.toHexString c)) color;
      palette = {
        surface1 = hex (surface 8);
        surface2 = hex (surface 16);
      }
      # Starship lowercases a style before it looks a name up in the palette.
      // lib.listToAttrs (
        map (name: lib.nameValuePair (lib.toLower name) scheme.${name}) [
          "base05"
          "base0A"
          "base0B"
          "base0C"
          "base0D"
          "base0E"
        ]
      );
    in
    ''
      palette = "scheme"
      ${builtins.readFile ../starship.toml}
      [palettes.scheme]
      ${lib.concatStrings (lib.mapAttrsToList (name: color: "${name} = \"${color}\"\n") palette)}'';
}
