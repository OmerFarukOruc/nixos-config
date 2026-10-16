# The tiling look: the Glass look with rounded corners, Krohnkite tiling with
# gaps, and three floating top panels in place of the top bar.
{
  config,
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  isPlasma = sessions.hasDesktop osConfig.oruc.machine "plasma";
  active = config.oruc.plasma.look == "tiling";
  gap = 8;
in
{
  config = lib.mkIf isPlasma (
    lib.mkMerge [
      {
        home.packages = [ pkgs.kdePackages.krohnkite ];
        programs.plasma.configFile.kwinrc.Plugins.krohnkiteEnabled = active;
      }

      (lib.mkIf active {
        oruc.plasma = {
          glass = {
            enable = true;
            cornerRadius = 10;
          };
          panelLayout = "islands";
        };

        # Krohnkite tiles every new window. Dialogs and the windows listed here
        # float.
        programs.plasma.configFile.kwinrc.Script-krohnkite = {
          screenGapTop = gap;
          screenGapBottom = gap;
          screenGapLeft = gap;
          screenGapRight = gap;
          screenGapBetween = gap;
          floatingClass = lib.concatStringsSep "," [
            "org.kde.kcalc"
            "org.freedesktop.impl.portal.desktop.kde"
            "org.kde.polkit-kde-authentication-agent-1"
          ];
        };
      })
    ]
  );
}
