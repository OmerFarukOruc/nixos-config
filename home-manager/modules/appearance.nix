{
  config,
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  cfg = osConfig.oruc.machine;
  scheme = osConfig.scheme.withHashtag;
  theme = osConfig.oruc.theme;
  hasNiri = sessions.hasDesktop cfg "niri";
  hasPlasma = sessions.hasDesktop cfg "plasma";

  # Named colors of libadwaita, which adw-gtk3 reuses for GTK 3.
  gtkColors = ''
    @define-color accent_color ${scheme.base0D};
    @define-color accent_bg_color ${scheme.base0D};
    @define-color accent_fg_color ${scheme.base00};
    @define-color destructive_color ${scheme.base08};
    @define-color destructive_bg_color ${scheme.base08};
    @define-color destructive_fg_color ${scheme.base00};
    @define-color success_color ${scheme.base0B};
    @define-color success_bg_color ${scheme.base0B};
    @define-color success_fg_color ${scheme.base00};
    @define-color warning_color ${scheme.base0A};
    @define-color warning_bg_color ${scheme.base0A};
    @define-color warning_fg_color ${scheme.base00};
    @define-color error_color ${scheme.base08};
    @define-color error_bg_color ${scheme.base08};
    @define-color error_fg_color ${scheme.base00};
    @define-color window_bg_color ${scheme.base00};
    @define-color window_fg_color ${scheme.base05};
    @define-color view_bg_color ${scheme.base00};
    @define-color view_fg_color ${scheme.base05};
    @define-color headerbar_bg_color ${scheme.base01};
    @define-color headerbar_fg_color ${scheme.base05};
    @define-color headerbar_border_color ${scheme.base02};
    @define-color headerbar_backdrop_color ${scheme.base00};
    @define-color card_bg_color ${scheme.base01};
    @define-color card_fg_color ${scheme.base05};
    @define-color dialog_bg_color ${scheme.base01};
    @define-color dialog_fg_color ${scheme.base05};
    @define-color popover_bg_color ${scheme.base01};
    @define-color popover_fg_color ${scheme.base05};
    @define-color sidebar_bg_color ${scheme.base01};
    @define-color sidebar_fg_color ${scheme.base05};
    @define-color sidebar_backdrop_color ${scheme.base00};
    @define-color sidebar_border_color ${scheme.base02};
    @define-color secondary_sidebar_bg_color ${scheme.base01};
    @define-color secondary_sidebar_fg_color ${scheme.base05};
    @define-color thumbnail_bg_color ${scheme.base01};
    @define-color thumbnail_fg_color ${scheme.base05};
  '';
in
{
  # Plasma writes the GTK and cursor settings itself, so a machine with a Plasma
  # session leaves them to Plasma and its niri session inherits them.
  config = lib.mkMerge [
    (lib.mkIf (hasNiri && !hasPlasma) {
      home.pointerCursor = {
        inherit (theme.cursor) name size;
        package = pkgs.bibata-cursors;
        enable = true;
        gtk.enable = true;
        x11.enable = true;
      };

      gtk = {
        enable = true;
        theme = {
          name = theme.gtk;
          package = pkgs.adw-gtk3;
        };
        iconTheme = {
          name = theme.icons;
          package = pkgs.papirus-icon-theme;
        };
        colorScheme = if theme.isLight then "light" else "dark";
        gtk2.configLocation = "${config.xdg.configHome}/gtk-2.0/gtkrc";
        gtk3.extraCss = gtkColors;
        gtk4.extraCss = gtkColors;
      };
    })

    (lib.mkIf hasPlasma {
      # plasma-manager names this cursor and icon theme, and niri's theme.kdl the cursor.
      home.packages = [
        pkgs.bibata-cursors
        pkgs.papirus-icon-theme
      ];
    })

    (lib.mkIf hasNiri {
      # Plasma's platform theme gives every Qt application the colors and icons
      # that kdeglobals names, which theme.nix writes from the scheme. qt6ct is
      # not an alternative: it left Dolphin light (observed 2026-09-21).
      qt = {
        enable = true;
        platformTheme.name = "kde";
      };
    })
  ];
}
