{
  config,
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  applyWallpaper = pkgs.writeShellApplication {
    name = "oruc-plasma-wallpaper";
    runtimeInputs = [
      pkgs.kdePackages.plasma-workspace
      config.oruc.wallpaper
    ];
    text = ''
      plasma-apply-wallpaperimage --fill-mode preserveAspectCrop "$(oruc-wallpaper-path)"
    '';
  };
in
{
  config = lib.mkIf (sessions.hasShell osConfig.oruc.machine "plasma") {
    home.packages = [ pkgs.kdePackages.spectacle ];

    programs.plasma.startup.startupScript.oruc-wallpaper = {
      text = lib.getExe applyWallpaper;
      priority = 4;
      runAlways = true;
    };

    oruc.variantReloads.wallpaper = ''
      systemctl --user is-active -q plasma-plasmashell.service || exit 0
      ${lib.getExe applyWallpaper}
    '';
  };
}
