# Settings of the KDE apps that plasma-manager knows. Plasma 6 installs
# Okular, and home-manager/profiles/personal.nix installs Kate, so neither module
# adds a package.
{
  config,
  lib,
  osConfig,
  sessions,
  ...
}:
let
  isPlasma = sessions.hasDesktop osConfig.oruc.machine "plasma";
  inherit (config.oruc) theme;
  scheme = config.scheme.withHashtag;

  color = slot: { text-color = scheme.${slot}; };
  bold = slot: color slot // { bold = true; };

  # A KSyntaxHighlighting theme in the Base16 scheme's colors, after the Base16
  # styling guidelines. programs.kate.editor.theme.src reads its file while Nix
  # evaluates, and `nix flake check` failed to read a builtins.toFile path
  # ("path ... is not valid"), so the theme is written here and Kate gets only
  # its name.
  kateThemeName = "Oruc Base16";
  kateTheme = builtins.toJSON {
    metadata = {
      name = kateThemeName;
      revision = 1;
    };
    text-styles = {
      Normal = color "base05";
      Keyword = bold "base0E";
      Function = color "base0D";
      Variable = color "base08";
      ControlFlow = bold "base0E";
      Operator = color "base05";
      BuiltIn = color "base0C";
      Extension = bold "base0D";
      Preprocessor = color "base0A";
      Attribute = color "base0A";
      Char = color "base0B";
      SpecialChar = color "base0C";
      String = color "base0B";
      VerbatimString = color "base0B";
      SpecialString = color "base0C";
      Import = color "base0E";
      DataType = color "base0A";
      DecVal = color "base09";
      BaseN = color "base09";
      Float = color "base09";
      Constant = bold "base09";
      Comment = color "base03" // {
        italic = true;
      };
      Documentation = color "base03";
      Annotation = color "base0F";
      CommentVar = color "base0E";
      RegionMarker = color "base0D" // {
        background-color = scheme.base01;
      };
      Information = color "base0D";
      Warning = color "base09";
      Alert = bold "base08" // {
        background-color = scheme.base01;
      };
      Error = color "base08" // {
        underline = true;
      };
      Others = color "base0C";
    };
    editor-colors = lib.mapAttrs (_: slot: scheme.${slot}) {
      BackgroundColor = "base00";
      BracketMatching = "base02";
      CodeFolding = "base01";
      CurrentLine = "base01";
      CurrentLineNumber = "base05";
      IconBorder = "base00";
      IndentationLine = "base02";
      LineNumbers = "base03";
      MarkBookmark = "base0D";
      MarkBreakpointActive = "base08";
      MarkBreakpointDisabled = "base0E";
      MarkBreakpointReached = "base0A";
      MarkError = "base08";
      MarkExecution = "base0C";
      MarkWarning = "base09";
      ModifiedLines = "base09";
      ReplaceHighlight = "base03";
      SavedLines = "base0B";
      SearchHighlight = "base03";
      Separator = "base02";
      SpellChecking = "base08";
      TabMarker = "base02";
      TemplateBackground = "base01";
      TemplateFocusedPlaceholder = "base03";
      TemplatePlaceholder = "base02";
      TemplateReadOnlyPlaceholder = "base01";
      TextSelection = "base02";
      WordWrapMarker = "base02";
    };
  };
in
{
  config = lib.mkIf isPlasma {
    programs.kate = {
      enable = true;
      package = null;
      editor = {
        font = {
          family = theme.fonts.mono;
          pointSize = 10;
        };
        theme.name = kateThemeName;
        # The module writes every editor setting; these two keep Kate's own
        # defaults.
        brackets.automaticallyAddClosing = true;
        indent.showLines = false;
      };
    };

    xdg.dataFile."org.kde.syntax-highlighting/themes/${kateThemeName}.theme".text = kateTheme;

    programs.okular = {
      enable = true;
      package = null;
      general = {
        smoothScrolling = true;
        viewContinuous = true;
        zoomMode = "fitWidth";
        openFileInTabs = true;
      };
    };
  };
}
