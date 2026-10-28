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
  pathPreview = "if [ -d {} ]; then ${treePreview}; else ${batPreview}; fi";
  previewWindow = "--preview-window=right:50%:wrap";

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
  imports = [ ./scheme.nix ];

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = false;
    autocd = true;
    setOptions = [
      "CORRECT"
      "AUTO_PUSHD"
    ];
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

        eval "$(${lib.getExe config.programs.fzf.package} --zsh)"
        bindkey -r '^R'
      '')
      (lib.mkOrder 2000 ''
        if [[ -z "''${CLAUDECODE:-}" \
           && -z "''${CLAUDE_CODE_NEW_INIT:-}" \
           && -z "''${CODEX_SESSION_ID:-}" \
           && -z "''${CODEX_THREAD_ID:-}" \
           && -z "''${OPENCODE_DB:-}" \
           && -z "''${CURSOR_AGENT:-}" \
           && -z "''${GROK_SESSION_ID:-}" ]]; then
          eval "$(${lib.getExe config.programs.atuin.package} init zsh --disable-up-arrow)"
        fi

        for keymap in emacs viins; do
          bindkey -M "$keymap" '^P' history-substring-search-up
          bindkey -M "$keymap" '^N' history-substring-search-down
        done
      '')
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
  programs.nix-index-database.comma.enable = true;

  programs.starship = {
    enable = true;
    enableZshIntegration = true;
  };
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
