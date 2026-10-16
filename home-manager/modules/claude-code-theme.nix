# Claude Code's color theme from the Base16 scheme. The dotfiles settings.json
# selects `custom:scheme` on every host, and its desktop-sync.sh leaves
# ~/.claude/themes/scheme.json to this file on nixos-rog; the other hosts get a
# static copy from the dotfiles repository. Claude Code reloads a changed theme
# file, so `theme` recolors open sessions too.
{
  config,
  lib,
  ...
}:
let
  inherit (config.oruc.theme) isLight;
  slot =
    name:
    map (channel: lib.toInt config.scheme."${name}-rgb-${channel}") [
      "r"
      "g"
      "b"
    ];
  # Each channel PERCENT of the way from A to B.
  mix =
    a: b: percent:
    lib.zipListsWith (x: y: (x * (100 - percent) + y * percent) / 100) a b;
  bg = slot "base00";
  fg = slot "base05";
  # Some schemes (Catppuccin) keep base03 and base04 as surface colors, so the
  # dim text pulls them toward the text color: hints stay above 4.5:1 and
  # subtle text above 3:1 in the schemes on the machine record.
  inactive = mix (slot "base04") fg 40;
  subtle = mix (slot "base03") fg 25;
  # Claude Code's own themes draw a shimmer lighter than its color in both
  # variants, so it moves toward the lightest slot.
  shimmer = color: mix color (slot (if isLight then "base00" else "base07")) 35;
  fastMode = mix (slot "base09") (slot "base0A") 50;
  rainbow = {
    red = slot "base08";
    orange = slot "base09";
    yellow = slot "base0A";
    green = slot "base0B";
    blue = slot "base0D";
    indigo = mix (slot "base0D") (slot "base0E") 35;
    violet = slot "base0E";
  };

  # Every color token of Claude Code's built-in themes; a token it does not
  # know is ignored, so a renamed one falls back to the base theme.
  colors = {
    text = slot "base06";
    inverseText = bg;
    inherit inactive subtle;
    inactiveShimmer = shimmer inactive;
    promptBorder = inactive;
    promptBorderShimmer = shimmer inactive;
    claude = slot "base09";
    claudeShimmer = shimmer (slot "base09");
    permission = slot "base0A";
    permissionShimmer = shimmer (slot "base0A");
    success = slot "base0B";
    warning = slot "base0A";
    warningShimmer = shimmer (slot "base0A");
    error = slot "base08";
    merged = slot "base0E";
    suggestion = slot "base0D";
    remember = slot "base0D";
    ide = slot "base0D";
    planMode = slot "base0C";
    autoAccept = slot "base0E";
    autoAcceptShimmer = shimmer (slot "base0E");
    skill = slot "base0E";
    effortUltra = slot "base0E";
    bashBorder = mix (slot "base08") (slot "base0E") 50;
    inherit fastMode;
    fastModeShimmer = shimmer fastMode;
    background = slot "base0C";
    claudeBlue_FOR_SYSTEM_SPINNER = slot "base0D";
    claudeBlueShimmer_FOR_SYSTEM_SPINNER = shimmer (slot "base0D");
    diffAdded = mix bg (slot "base0B") 25;
    diffRemoved = mix bg (slot "base08") 25;
    diffAddedDimmed = mix bg (slot "base0B") 12;
    diffRemovedDimmed = mix bg (slot "base08") 12;
    diffAddedWord = mix bg (slot "base0B") 50;
    diffRemovedWord = mix bg (slot "base08") 50;
    # A blend toward the text color, because schemes disagree on whether
    # base01 is lighter or darker than base00.
    userMessageBackground = mix bg fg 8;
    userMessageBackgroundHover = mix bg fg 14;
    composerSidebarBackground = mix bg fg 5;
    bashMessageBackgroundColor = mix bg (slot "base0E") 12;
    memoryBackgroundColor = mix bg (slot "base0C") 12;
    selectionBg = slot "base02";
    rate_limit_fill = slot "base0D";
    rate_limit_empty = mix bg (slot "base0D") 30;
    briefLabelYou = slot "base0D";
    briefLabelClaude = slot "base09";
    red_FOR_SUBAGENTS_ONLY = slot "base08";
    orange_FOR_SUBAGENTS_ONLY = slot "base09";
    yellow_FOR_SUBAGENTS_ONLY = slot "base0A";
    green_FOR_SUBAGENTS_ONLY = slot "base0B";
    cyan_FOR_SUBAGENTS_ONLY = slot "base0C";
    blue_FOR_SUBAGENTS_ONLY = slot "base0D";
    purple_FOR_SUBAGENTS_ONLY = mix (slot "base0D") (slot "base0E") 50;
    pink_FOR_SUBAGENTS_ONLY = mix (slot "base0E") (slot "base08") 50;
    professionalBlue = slot "base0D";
    chromeYellow = slot "base0A";
    clawd_body = slot "base09";
    clawd_background = bg;
  }
  // lib.mapAttrs' (name: color: lib.nameValuePair "rainbow_${name}" color) rainbow
  // lib.mapAttrs' (name: color: lib.nameValuePair "rainbow_${name}_shimmer" (shimmer color)) rainbow;
in
{
  config = lib.mkIf config.programs.claude-code.enable {
    # `/theme` saves an edited theme over the link, and Home Manager replaces it.
    home.file.".claude/themes/scheme.json" = {
      force = true;
      text = builtins.toJSON {
        name = "Base16 ${config.scheme.scheme-name}";
        base = if isLight then "light" else "dark";
        overrides = lib.mapAttrs (_: color: "rgb(${lib.concatMapStringsSep "," toString color})") colors;
      };
    };
  };
}
