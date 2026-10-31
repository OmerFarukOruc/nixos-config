{
  config,
  lib,
  ...
}:
let
  contrast = import ../../nixosModules/contrast.nix { inherit lib; };

  statusline =
    { scheme, theme }:
    let
      rgb = hex: lib.concatMapStringsSep ";" toString (contrast.channels hex);
      text = {
        dir = scheme.base02;
        git = scheme.base09;
        model = scheme.base0D;
        account = scheme.base0C;
        clock = scheme.base0E;
        cost = scheme.base0F;
      };
      bars = {
        ctx = scheme.base01;
        five_hour = scheme.base02;
        seven_day = scheme.base01;
      };
      legible = background: color: rgb (contrast.legibleOn scheme [ background ] color);
    in
    builtins.toJSON {
      segments =
        lib.mapAttrs (_: background: {
          bg = rgb background;
          fg = rgb (theme.readableOn background);
        }) text
        // lib.mapAttrs (_: background: { bg = rgb background; }) bars;
      used = lib.mapAttrs (_: background: {
        low = legible background scheme.base0B;
        mid = legible background scheme.base0A;
        high = legible background scheme.base08;
      }) bars;
    };

  render =
    { scheme, theme }:
    let
      inherit (theme) isLight;
      slot = theme.rgb;
      mix =
        a: b: percent:
        lib.zipListsWith (x: y: (x * (100 - percent) + y * percent) / 100) a b;
      bg = slot "base00";
      fg = slot "base05";
      inactive = mix (slot "base04") fg 40;
      subtle = mix (slot "base03") fg 25;
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
    builtins.toJSON {
      name = "Base16 ${scheme.scheme-name}";
      base = theme.polarity;
      overrides = lib.mapAttrs (_: color: "rgb(${lib.concatMapStringsSep "," toString color})") colors;
    };
in
{
  config = lib.mkIf config.programs.claude-code.enable {
    oruc.themeFiles.".claude/themes/scheme.json" = render;
    oruc.themeCopies = [ ".claude/themes/scheme.json" ];
    oruc.themeFacts.statusline = statusline;
  };
}
