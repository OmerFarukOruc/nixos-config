# The Klassy look: the Klassy window decoration, Qt style and Plasma style with
# the opaque Base16 scheme and KWin's own blur. Klassy keeps its own settings in
# ~/.config/klassy/klassyrc, which its settings app writes.
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
          colorScheme = "OrucBase16";
          widgetStyle = "Klassy";
        };

        programs.plasma = {
          workspace = {
            theme = if osConfig.oruc.theme.isLight then "klassy-light" else "klassy-dark";
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
