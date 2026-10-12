{
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  inherit (osConfig.oruc.theme) wallpaper;
in
{
  config = lib.mkIf (sessions.hasShell osConfig.oruc.machine "plasma") {
    home.packages = [ pkgs.kdePackages.spectacle ];

    systemd.user.services.oruc-plasma-wallpaper = lib.mkIf (wallpaper != null) {
      Unit = {
        Description = "Apply the selected Plasma wallpaper";
        # Only a Plasma session reaches plasma-workspace.target.
        After = [
          "plasma-workspace.target"
          "plasma-plasmashell.service"
        ];
        PartOf = [ "plasma-workspace.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${lib.getExe' pkgs.kdePackages.plasma-workspace "plasma-apply-wallpaperimage"} --fill-mode preserveAspectCrop ${wallpaper}";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = [ "plasma-workspace.target" ];
    };
  };
}
