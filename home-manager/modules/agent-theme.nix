{
  config,
  lib,
  ...
}:
let
  contrast = import ../../nixosModules/contrast.nix { inherit lib; };
  home = config.home.homeDirectory;
  hex = color: "#${lib.toLower color}";
  tintOn =
    scheme: pct: color:
    hex (contrast.mixHex pct color scheme.base00);
  codeThemes = lib.importJSON ./codex-code-themes.json;
  nameRules = [
    {
      pattern = "catppuccin-.*";
      id = "catppuccin";
    }
    {
      pattern = "dracula";
      id = "dracula";
    }
    {
      pattern = "gruvbox-.*";
      id = "gruvbox";
    }
    {
      pattern = "nord";
      id = "nord";
    }
    {
      pattern = "rose-pine.*";
      id = "rose-pine";
    }
    {
      pattern = "solarized-.*";
      id = "solarized";
    }
    {
      pattern = "tokyo-night-.*";
      id = "tokyo-night";
    }
    {
      pattern = "everforest.*";
      id = "everforest";
    }
    {
      pattern = "github.*";
      id = "github";
    }
    {
      pattern = "ayu-.*";
      id = "ayu";
    }
    {
      pattern = "monokai";
      id = "monokai";
    }
    {
      pattern = "one-light|onedark.*";
      id = "one";
    }
    {
      pattern = "material.*";
      id = "material";
    }
    {
      pattern = "xcode-dusk";
      id = "xcode";
    }
  ];
  codeTheme =
    { scheme, theme }:
    let
      offered = builtins.filter (variant: variant.variant == theme.polarity) codeThemes;
      ids = map (variant: variant.id) offered;
      named = lib.findFirst (
        rule: builtins.match rule.pattern theme.slug != null && builtins.elem rule.id ids
      ) null nameRules;
      score =
        variant:
        0.55 * contrast.oklabDistanceSquared scheme.base00 variant.background
        + 0.27 * contrast.oklabDistanceSquared scheme.base05 variant.foreground
        + 0.18 * contrast.oklabDistanceSquared scheme.base0D variant.accent;
      scored = map (variant: {
        inherit (variant) id;
        score = score variant;
      }) offered;
      nearest = lib.foldl' (
        best: next:
        if next.score < best.score || (next.score == best.score && next.id < best.id) then next else best
      ) (builtins.head scored) (builtins.tail scored);
    in
    if named != null then named.id else nearest.id;

  codexSettings =
    { scheme, theme }:
    let
      side = lib.toSentenceCase theme.polarity;
    in
    builtins.toJSON {
      tui.theme = "oruc";
      desktop = {
        "appearance${side}CodeThemeId" = codeTheme { inherit scheme theme; };
        "appearance${side}ChromeTheme" = {
          accent = hex scheme.base0D;
          surface = hex scheme.base00;
          ink = hex (
            contrast.mostReadable scheme.base00 [
              scheme.base05
              scheme.base06
              scheme.base07
              "000000"
              "ffffff"
            ]
          );
          accentSource = "custom";
          contrast = 100;
          opaqueWindows = true;
          fonts = { };
          semanticColors = {
            diffAdded = hex scheme.base0B;
            diffRemoved = hex scheme.base08;
            skill = hex scheme.base0E;
          };
        };
      };
    };

  tmTheme =
    { scheme, ... }:
    let
      entry = scope: slot: style: ''
        <dict>
          <key>scope</key><string>${scope}</string>
          <key>settings</key><dict>
            <key>foreground</key><string>${hex scheme.${slot}}</string>${
              lib.optionalString (style != "") "\n      <key>fontStyle</key><string>${style}</string>"
            }
          </dict>
        </dict>
      '';
      scopes = [
        [
          "comment, punctuation.definition.comment"
          "base03"
          "italic"
        ]
        [
          "keyword.operator, punctuation"
          "base05"
          ""
        ]
        [
          "keyword, storage, meta.selector"
          "base0E"
          ""
        ]
        [
          "variable, entity.name.tag"
          "base08"
          ""
        ]
        [
          "entity.name.function, support.function.any-method, variable.function, meta.require"
          "base0D"
          ""
        ]
        [
          "support.class, entity.name.class, entity.name.type"
          "base0A"
          ""
        ]
        [
          "support.function, string.regexp, constant.character.escape"
          "base0C"
          ""
        ]
        [
          "string, constant.other.symbol, entity.other.inherited-class, markup.raw.inline"
          "base0B"
          ""
        ]
        [
          "constant, keyword.other.unit, entity.other.attribute-name, meta.link, markup.quote"
          "base09"
          ""
        ]
        [
          "punctuation.section.embedded, variable.interpolation"
          "base0F"
          ""
        ]
        [
          "markup.heading, entity.name.section"
          "base0D"
          "bold"
        ]
        [
          "markup.bold"
          "base0A"
          "bold"
        ]
        [
          "markup.italic"
          "base0E"
          "italic"
        ]
        [
          "markup.inserted"
          "base0B"
          ""
        ]
        [
          "markup.deleted, invalid"
          "base08"
          ""
        ]
        [
          "markup.changed"
          "base0E"
          ""
        ]
      ];
    in
    ''
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>name</key><string>${lib.escapeXML scheme.scheme-name}</string>
        <key>settings</key>
        <array>
          <dict>
            <key>settings</key><dict>
              <key>background</key><string>${hex scheme.base00}</string>
              <key>foreground</key><string>${hex scheme.base05}</string>
              <key>caret</key><string>${hex scheme.base05}</string>
              <key>invisibles</key><string>${hex scheme.base03}</string>
              <key>lineHighlight</key><string>${hex scheme.base01}</string>
              <key>selection</key><string>${hex scheme.base02}</string>
            </dict>
          </dict>
      ${
        lib.concatMapStrings (
          row: entry (builtins.elemAt row 0) (builtins.elemAt row 1) (builtins.elemAt row 2)
        ) scopes
      }  </array>
      </dict>
      </plist>
    '';

  opencodeTheme =
    { scheme, ... }:
    let
      slot = name: hex scheme.${name};
      tint = tintOn scheme;
    in
    builtins.toJSON {
      "$schema" = "https://opencode.ai/theme.json";
      defs = { };
      theme = {
        primary = slot "base0D";
        secondary = slot "base0E";
        accent = slot "base0C";
        error = slot "base08";
        warning = slot "base0A";
        success = slot "base0B";
        info = slot "base0C";
        text = slot "base05";
        textMuted = slot "base04";
        background = slot "base00";
        backgroundPanel = slot "base01";
        backgroundElement = slot "base02";
        border = slot "base03";
        borderActive = slot "base0D";
        borderSubtle = slot "base02";
        diffAdded = slot "base0B";
        diffRemoved = slot "base08";
        diffContext = slot "base04";
        diffHunkHeader = slot "base0C";
        diffHighlightAdded = slot "base0B";
        diffHighlightRemoved = slot "base08";
        diffAddedBg = tint 15 scheme.base0B;
        diffRemovedBg = tint 15 scheme.base08;
        diffContextBg = slot "base01";
        diffLineNumber = slot "base03";
        diffAddedLineNumberBg = tint 25 scheme.base0B;
        diffRemovedLineNumberBg = tint 25 scheme.base08;
        markdownText = slot "base05";
        markdownHeading = slot "base0D";
        markdownLink = slot "base0C";
        markdownLinkText = slot "base0D";
        markdownCode = slot "base0B";
        markdownBlockQuote = slot "base04";
        markdownEmph = slot "base0E";
        markdownStrong = slot "base0A";
        markdownHorizontalRule = slot "base03";
        markdownListItem = slot "base0D";
        markdownListEnumeration = slot "base0C";
        markdownImage = slot "base0C";
        markdownImageText = slot "base0D";
        markdownCodeBlock = slot "base05";
        syntaxComment = slot "base03";
        syntaxKeyword = slot "base0E";
        syntaxFunction = slot "base0D";
        syntaxVariable = slot "base08";
        syntaxString = slot "base0B";
        syntaxNumber = slot "base09";
        syntaxType = slot "base0A";
        syntaxOperator = slot "base0C";
        syntaxPunctuation = slot "base05";
      };
    };

  piTheme =
    { scheme, theme }:
    let
      slot = name: hex scheme.${name};
      tint = tintOn scheme;
    in
    builtins.toJSON {
      "$schema" = "https://pi.dev/schemas/theme.schema.json";
      name = "oruc";
      appearance = theme.polarity;
      colors = {
        accent = slot "base0D";
        border = slot "base03";
        borderAccent = slot "base0E";
        borderMuted = slot "base02";
        success = slot "base0B";
        error = slot "base08";
        warning = slot "base0A";
        muted = slot "base04";
        dim = slot "base03";
        text = slot "base05";
        thinkingText = slot "base04";
        selectedBg = slot "base02";
        scrollbarTrack = slot "base01";
        scrollbarThumb = slot "base03";
        searchMatchBg = tint 25 scheme.base0A;
        searchMatchText = slot "base05";
        userMessageBg = slot "base01";
        userMessageText = slot "base05";
        customMessageBg = tint 20 scheme.base0E;
        customMessageText = slot "base04";
        customMessageLabel = slot "base0E";
        toolPendingBg = slot "base01";
        toolSuccessBg = tint 20 scheme.base0B;
        toolErrorBg = tint 20 scheme.base08;
        toolTitle = slot "base05";
        toolOutput = slot "base04";
        mdHeading = slot "base0A";
        mdLink = slot "base0D";
        mdLinkUrl = slot "base04";
        mdCode = slot "base0E";
        mdCodeBlock = slot "base0B";
        mdCodeBlockBorder = slot "base03";
        mdQuote = slot "base04";
        mdQuoteBorder = slot "base03";
        mdHr = slot "base03";
        mdListBullet = slot "base0E";
        toolDiffAdded = slot "base0B";
        toolDiffRemoved = slot "base08";
        toolDiffContext = slot "base04";
        syntaxComment = slot "base03";
        syntaxKeyword = slot "base0E";
        syntaxFunction = slot "base0D";
        syntaxVariable = slot "base08";
        syntaxString = slot "base0B";
        syntaxNumber = slot "base09";
        syntaxType = slot "base0A";
        syntaxOperator = slot "base0C";
        syntaxPunctuation = slot "base05";
        thinkingOff = slot "base03";
        thinkingMinimal = slot "base04";
        thinkingLow = slot "base0C";
        thinkingMedium = slot "base0D";
        thinkingHigh = slot "base0E";
        thinkingXhigh = slot "base09";
        thinkingMax = slot "base08";
        bashMode = slot "base0B";
      };
      export = {
        pageBg = slot "base00";
        cardBg = slot "base01";
        infoBg = tint 25 scheme.base0A;
      };
    };

  gumAccent = "4";
  gumHeader = "5";
  gumMuted = "8";
in
{
  options.oruc.piTheme = lib.mkEnableOption "pi's oruc theme from the theme pack";

  config = lib.mkMerge [
    {
      oruc.themeFiles = {
        ".codex/themes/oruc.tmTheme" = tmTheme;
        ".config/opencode/themes/oruc.json" = opencodeTheme;
      };
      oruc.themeCopies = [ ".codex/themes/oruc.tmTheme" ];
      oruc.themeFacts.codex-settings = codexSettings;
      oruc.appSettings = {
        codex = {
          label = "Codex or the ChatGPT app";
          executables = [
            {
              package = "codex";
              path = "libexec/codex/bin/codex";
            }
            {
              package = "chatgpt";
              path = "lib/chatgpt/ChatGPT";
            }
          ];
          servers = [ "app-server" ];
          files = [
            {
              path = "${home}/.codex/config.toml";
              format = "toml";
              fact = "codex-settings";
            }
          ];
        };
        opencode = {
          label = "opencode";
          executables = [
            {
              package = "opencode[^/]*";
              path = ''bin/\.opencode[^/]*-wrapped'';
            }
          ];
          servers = [ "serve" ];
          terminalSignal = {
            name = "SIGUSR2";
            subcommands = [
              "acp"
              "api"
              "auth"
              "debug"
              "mcp"
              "mini"
              "models"
              "pair"
              "plugin"
              "reload"
              "run"
              "serve"
              "service"
              "session"
              "stats"
              "uninstall"
              "update"
              "upgrade"
            ];
            valueFlags = [
              "--completions"
              "--log-level"
              "--prompt"
              "--server"
              "--session"
              "-s"
            ];
          };
          files = [
            {
              path = "${config.xdg.configHome}/opencode/cli.json";
              format = "json";
              values.theme.name = "oruc";
            }
          ];
        };
      };

      home.sessionVariables = {
        GUM_CHOOSE_CURSOR_FOREGROUND = gumAccent;
        GUM_CHOOSE_HEADER_FOREGROUND = gumHeader;
        GUM_CHOOSE_SELECTED_FOREGROUND = gumAccent;
        GUM_CONFIRM_PROMPT_FOREGROUND = gumHeader;
        GUM_CONFIRM_SELECTED_FOREGROUND = "0";
        GUM_CONFIRM_SELECTED_BACKGROUND = gumAccent;
        GUM_CONFIRM_UNSELECTED_FOREGROUND = "7";
        GUM_CONFIRM_UNSELECTED_BACKGROUND = "0";
        GUM_FILE_CURSOR_FOREGROUND = gumAccent;
        GUM_FILE_SYMLINK_FOREGROUND = "6";
        GUM_FILE_DIRECTORY_FOREGROUND = gumHeader;
        GUM_FILE_PERMISSIONS_FOREGROUND = gumMuted;
        GUM_FILE_SELECTED_FOREGROUND = gumAccent;
        GUM_FILE_FILE_SIZE_FOREGROUND = gumMuted;
        GUM_FILE_HEADER_FOREGROUND = gumHeader;
        GUM_FILTER_INDICATOR_FOREGROUND = gumAccent;
        GUM_FILTER_SELECTED_PREFIX_FOREGROUND = gumAccent;
        GUM_FILTER_UNSELECTED_PREFIX_FOREGROUND = gumMuted;
        GUM_FILTER_HEADER_FOREGROUND = gumHeader;
        GUM_FILTER_MATCH_FOREGROUND = gumAccent;
        GUM_FILTER_PROMPT_FOREGROUND = gumMuted;
        GUM_FILTER_PLACEHOLDER_FOREGROUND = gumMuted;
        GUM_INPUT_PLACEHOLDER_FOREGROUND = gumMuted;
        GUM_INPUT_CURSOR_FOREGROUND = gumAccent;
        GUM_INPUT_HEADER_FOREGROUND = gumMuted;
        GUM_PAGER_LINE_NUMBER_FOREGROUND = gumMuted;
        GUM_PAGER_MATCH_FOREGROUND = gumAccent;
        GUM_PAGER_MATCH_HIGH_FOREGROUND = "0";
        GUM_PAGER_MATCH_HIGH_BACKGROUND = "3";
        GUM_PAGER_HELP_FOREGROUND = gumMuted;
        GUM_SPIN_SPINNER_FOREGROUND = gumAccent;
        GUM_TABLE_SELECTED_FOREGROUND = gumAccent;
        GUM_WRITE_CURSOR_FOREGROUND = gumAccent;
        GUM_WRITE_HEADER_FOREGROUND = gumMuted;
        GUM_WRITE_PLACEHOLDER_FOREGROUND = gumMuted;
      };
    }
    (lib.mkIf config.oruc.piTheme {
      oruc.themeFiles.".pi/agent/themes/oruc.json" = piTheme;
      oruc.themeCopies = [ ".pi/agent/themes/oruc.json" ];
      oruc.appSettings.pi = {
        label = "pi";
        executables = [
          {
            package = "pi";
            path = "libexec/pi/pi";
          }
        ];
        files = [
          {
            path = "${home}/.pi/agent/settings.json";
            format = "json";
            values.theme = "oruc";
          }
        ];
      };
    })
  ];
}
