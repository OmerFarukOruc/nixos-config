{ lib }:
let
  themeValues = import ./theme-values.nix { inherit lib; };
  consoleSlots = scheme: (themeValues scheme).ansi;
in
{
  sddmConfUser =
    scheme:
    let
      color = scheme.withHashtag;
      onAccent = "#${(themeValues scheme).readableOn scheme.base0D}";
    in
    lib.generators.toINI { } {
      General = lib.mapAttrs (_: value: ''"${value}"'') {
        HeaderTextColor = color.base05;
        DateTextColor = color.base05;
        TimeTextColor = color.base05;

        FormBackgroundColor = color.base00;
        BackgroundColor = color.base00;
        DimBackgroundColor = color.base00;

        LoginFieldBackgroundColor = color.base05;
        PasswordFieldBackgroundColor = color.base05;
        LoginFieldTextColor = color.base05;
        PasswordFieldTextColor = color.base05;
        UserIconColor = color.base05;
        PasswordIconColor = color.base05;

        PlaceholderTextColor = color.base03;
        WarningColor = color.base08;

        LoginButtonTextColor = onAccent;
        LoginButtonBackgroundColor = color.base0D;
        SystemButtonsIconsColor = color.base05;
        SessionButtonTextColor = color.base05;
        VirtualKeyboardButtonTextColor = color.base05;

        DropdownTextColor = color.base05;
        DropdownSelectedBackgroundColor = color.base02;
        DropdownBackgroundColor = color.base01;

        HighlightTextColor = onAccent;
        HighlightBackgroundColor = color.base0D;

        HoverUserIconColor = color.base0D;
        HoverPasswordIconColor = color.base0D;
        HoverSystemButtonsIconsColor = color.base0D;
        HoverSessionButtonTextColor = color.base0D;
        HoverVirtualKeyboardButtonTextColor = color.base0D;
      };
    };

  consoleColors = scheme: map (slot: scheme.${slot}) (consoleSlots scheme);

  vtrgb =
    scheme:
    lib.concatMapStrings
      (
        channel:
        lib.concatMapStringsSep "," (slot: scheme."${slot}-rgb-${channel}") (consoleSlots scheme) + "\n"
      )
      [
        "r"
        "g"
        "b"
      ];

  limineStyle =
    scheme:
    let
      slots = consoleSlots scheme;
      palette = names: lib.concatMapStringsSep ";" (name: scheme.${name}) names;
    in
    {
      backdrop = scheme.base00;
      interface = {
        brandingColor = scheme.base0A;
        helpColor = scheme.base0C;
        helpColorBright = scheme.base09;
      };
      graphicalTerminal = {
        palette = palette (lib.take 8 slots);
        brightPalette = palette (lib.drop 8 slots);
        foreground = scheme.base06;
        brightForeground = scheme.base06;
        background = scheme.base00;
        brightBackground = scheme.base02;
      };
    };
}
