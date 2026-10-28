{
  config,
  lib,
  pkgs,
  sessions,
  ...
}:
let
  themed = sessions.hasAnyDesktop config.oruc.machine;
  scheme = config.scheme.withHashtag;
  # Themes/jake_the_dog.conf.user, which SDDM reads over the theme's own file,
  # so the fonts, layout and video stay Jake's. The values are quoted as in the
  # theme's own file.
  colors = lib.mapAttrs (_: color: ''"${color}"'') {
    HeaderTextColor = scheme.base05;
    DateTextColor = scheme.base05;
    TimeTextColor = scheme.base05;

    FormBackgroundColor = scheme.base00;
    BackgroundColor = scheme.base00;
    DimBackgroundColor = scheme.base00;

    # The theme draws these backgrounds at 20 percent opacity, in the color
    # of the text on them.
    LoginFieldBackgroundColor = scheme.base05;
    PasswordFieldBackgroundColor = scheme.base05;
    LoginFieldTextColor = scheme.base05;
    PasswordFieldTextColor = scheme.base05;
    UserIconColor = scheme.base05;
    PasswordIconColor = scheme.base05;

    PlaceholderTextColor = scheme.base03;
    WarningColor = scheme.base08;

    LoginButtonTextColor = scheme.base00;
    LoginButtonBackgroundColor = scheme.base0D;
    SystemButtonsIconsColor = scheme.base05;
    SessionButtonTextColor = scheme.base05;
    VirtualKeyboardButtonTextColor = scheme.base05;

    DropdownTextColor = scheme.base05;
    DropdownSelectedBackgroundColor = scheme.base02;
    DropdownBackgroundColor = scheme.base01;

    HighlightTextColor = scheme.base00;
    HighlightBackgroundColor = scheme.base0D;

    HoverUserIconColor = scheme.base0D;
    HoverPasswordIconColor = scheme.base0D;
    HoverSystemButtonsIconsColor = scheme.base0D;
    HoverSessionButtonTextColor = scheme.base0D;
    HoverVirtualKeyboardButtonTextColor = scheme.base0D;
  };
  jake = (pkgs.sddm-astronaut.override { embeddedTheme = "jake_the_dog"; }).overrideAttrs (old: {
    jakeColors = lib.generators.toINI { } { General = colors; };
    passAsFile = [ "jakeColors" ];
    postInstall = (old.postInstall or "") + ''
      themes=$out/share/sddm/themes/sddm-astronaut-theme/Themes
      chmod u+w "$themes"
      cp "$jakeColorsPath" "$themes/jake_the_dog.conf.user"
    '';
  });
in
{
  options.oruc.login.video = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    readOnly = true;
    description = "Video the login screen plays, for a lock screen that matches it, or null on a host without the themed login screen.";
  };

  config = lib.mkMerge [
    {
      oruc.login.video =
        if themed then
          "${jake}/share/sddm/themes/sddm-astronaut-theme/Backgrounds/jake_the_dog.mp4"
        else
          null;
    }

    (lib.mkIf themed {
      services.displayManager.sddm = {
        theme = "sddm-astronaut-theme";
        extraPackages = [ jake ];
      };
      environment.systemPackages = [ jake ];
      # The theme names its fonts but does not load them, so fontconfig must
      # find them.
      fonts.packages = [ jake ];
    })
  ];
}
