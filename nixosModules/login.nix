{
  config,
  lib,
  pkgs,
  sessions,
  ...
}:
let
  themed = sessions.hasDesktop config.oruc.machine "niri";
  jake = pkgs.sddm-astronaut.override { embeddedTheme = "jake_the_dog"; };
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

    # recovery.nix clears the theme in the recovery entry, in case the theme
    # renders a blank screen.
    (lib.mkIf themed {
      services.displayManager.sddm = {
        theme = "sddm-astronaut-theme";
        # The greeter finds the theme's Qt modules through its wrapper, which
        # takes them from the package's propagated inputs.
        extraPackages = [ jake ];
      };
      environment.systemPackages = [ jake ];
      # The theme names its fonts but does not load them, so fontconfig must
      # find them.
      fonts.packages = [ jake ];
    })
  ];
}
