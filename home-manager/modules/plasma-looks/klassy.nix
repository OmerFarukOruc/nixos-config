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
  active = config.oruc.plasma.look == "klassy";
in
{
  config = lib.mkIf isPlasma (
    lib.mkMerge [
      { home.packages = [ pkgs.klassy ]; }

      (lib.mkIf active {
        oruc.plasma = {
          widgetStyle = "Klassy";
        };

        programs.plasma = {
          workspace = {
            windowDecorations = {
              library = "org.kde.klassy";
              theme = "Klassy";
            };
          };
          kwin.effects.blur.enable = true;
        };
      })
    ]
  );
}
