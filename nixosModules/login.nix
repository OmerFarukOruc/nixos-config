{
  config,
  lib,
  pkgs,
  inputs,
  sessions,
  ...
}:
let
  cfg = config.oruc.machine;
  scheme = config.scheme.withHashtag;
  inherit (config.oruc.theme) wallpaper;

  # Each color in the theme's gruvbox.conf and the scheme slot that replaces it.
  palette = {
    "#282828" = "base00";
    "#3c3836" = "base01";
    "#504945" = "base02";
    "#665c54" = "base03";
    "#d79921" = "base04";
    "#ebdbb2" = "base06";
    "#fbf1c7" = "base07";
    "#fabd2f" = "base0A";
    "#98971a" = "base0B";
    "#b8bb26" = "base0B";
  };
  # Two passes, so a scheme color that equals another palette entry is not replaced twice.
  toPlaceholder = lib.concatMapStringsSep " " (hex: "-e 's/${hex}/@${palette.${hex}}@/Ig'") (
    builtins.attrNames palette
  );
  fromPlaceholder = lib.concatMapStringsSep " " (slot: "-e 's/@${slot}@/${scheme.${slot}}/g'") (
    lib.unique (builtins.attrValues palette)
  );
  # A color the theme no longer uses would leave its slot unthemed without a
  # build error.
  requirePalette = lib.concatMapStringsSep "\n" (
    hex: "grep -qi '${hex}' \"$conf\" || { echo '${hex} is missing from gruvbox.conf' >&2; exit 1; }"
  ) (builtins.attrNames palette);

  themed =
    inputs.silent-sddm.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs
      (old: {
        preFixup = (old.preFixup or "") + ''
          conf=$out/share/sddm/themes/silent/configs/gruvbox.conf
          ${requirePalette}
          sed -i ${toPlaceholder} "$conf"
          sed -i ${fromPlaceholder} "$conf"
        '';
      });
  wallpaperSettings = lib.optionalAttrs (wallpaper != null) {
    background = builtins.baseNameOf wallpaper;
    use-background-color = false;
  };
in
{
  imports = [ inputs.silent-sddm.nixosModules.default ];

  # recovery.nix turns this off in the recovery entry, in case the theme
  # renders a blank screen.
  config = lib.mkIf (sessions.hasDesktop cfg "niri") {
    programs.silentSDDM = {
      enable = true;
      theme = "gruvbox";
      package = themed;
      # The module's kwin default needs Plasma, which Plasma-less hosts lack.
      wayland = lib.mkIf (!sessions.hasDesktop cfg "plasma") {
        enable = true;
        compositor = "weston";
      };
      backgrounds = lib.optionalAttrs (wallpaper != null) { inherit wallpaper; };
      settings = {
        # Start at the login form instead of a "press any key" screen.
        LockScreen = {
          display = false;
        }
        // wallpaperSettings;
        LoginScreen = wallpaperSettings;
      };
    };
  };
}
