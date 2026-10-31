{
  config,
  lib,
  pkgs,
  sessions,
  ...
}:
let
  themed = sessions.hasAnyDesktop config.oruc.machine;
  colorsFile = "/var/lib/oruc/theme/sddm/jake_the_dog.conf.user";
  jake = (pkgs.sddm-astronaut.override { embeddedTheme = "jake_the_dog"; }).overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      themes=$out/share/sddm/themes/sddm-astronaut-theme/Themes
      chmod u+w "$themes"
      ln -s ${colorsFile} "$themes/jake_the_dog.conf.user"
    '';
  });
in
{
  options.oruc.login.colorsFile = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    readOnly = true;
    description = "File that the login screen reads its colours from, written by oruc-theme-root, or null on a host without the themed login screen.";
  };

  options.oruc.login.video = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    readOnly = true;
    description = "Video the login screen plays, for a lock screen that matches it, or null on a host without the themed login screen.";
  };

  config = lib.mkMerge [
    {
      oruc.login.colorsFile = if themed then colorsFile else null;
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
