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

    systemd.user.services.oruc-plasma-wallpaper = {
      Unit = {
        Description = "Apply the selected Plasma wallpaper";
        After = [
          "plasma-workspace.target"
          "plasma-plasmashell.service"
        ];
        PartOf = [ "plasma-workspace.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = lib.getExe applyWallpaper;
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = [ "plasma-workspace.target" ];
    };

    oruc.variantReloads.wallpaper = ''
      systemctl --user is-active -q plasma-plasmashell.service || exit 0
      ${lib.getExe applyWallpaper}
    '';
  };
}
