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
  scheme = config.scheme.withHashtag;
  theme = config.oruc.theme;
  hasNiri = sessions.hasDesktop cfg "niri";
  hasPlasma = sessions.hasDesktop cfg "plasma";
  kreadconfig = lib.getExe' pkgs.kdePackages.kconfig "kreadconfig6";
  kwriteconfig = lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6";

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
  # Plasma writes the GTK settings and the cursor itself, so a machine with a
  # Plasma session leaves them to Plasma and its niri session inherits them. Only
  # the scheme's named colors are ours there (the Plasma branch below).
  config = lib.mkMerge [
    (lib.mkIf (hasNiri && !hasPlasma) {
      # The cursor follows the machine record's scheme, because its name goes
      # into XCURSOR_THEME in the session-variables package, which `theme`
      # cannot switch (variants.nix).
      home.pointerCursor = {
        inherit (osConfig.oruc.theme.cursor) name size;
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
      # plasma-manager names this cursor and icon theme, and niri's theme.kdl the
      # cursor. adw-gtk3 is the GTK 3 theme that reads the named colors.
      home.packages = [
        pkgs.adw-gtk3
        pkgs.bibata-cursors
        pkgs.papirus-icon-theme
      ];

      # kde-gtk-config (kded) owns gtk.css and replaces it with a regular file
      # each time it applies a color scheme, so gtk.css cannot be a Home Manager
      # link. It keeps the file's content and only appends its own
      # `@import 'colors.css';`, so the import below survives. Its colors.css
      # defines only names that end in `_breeze`, which do not overlap ours, so
      # the order of the two imports does not matter.
      xdg.configFile."gtk-3.0/oruc-colors.css".text = gtkColors;
      xdg.configFile."gtk-4.0/oruc-colors.css".text = gtkColors;

      home.activation.gtkColors = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        if [[ ! -v DRY_RUN ]]; then
          for gtkDir in gtk-3.0 gtk-4.0; do
            gtkCss=${config.xdg.configHome}/$gtkDir/gtk.css
            gtkImport="@import 'oruc-colors.css';"
            mkdir -p "''${gtkCss%/*}"
            if [[ -L $gtkCss ]]; then
              warnEcho "$gtkCss is a link, so it cannot import oruc-colors.css."
            elif ! grep -qsF "$gtkImport" "$gtkCss"; then
              { [[ -s $gtkCss ]] && printf '\n'; printf '%s\n' "$gtkImport"; } >>"$gtkCss"
            fi
          done
          unset gtkDir gtkCss gtkImport

          # Only GTK 3 reads the theme name. The name is ours while it is unset
          # or already one of adw-gtk3's, so a theme chosen in System Settings
          # stays.
          gtkSettings=${config.xdg.configHome}/gtk-3.0/settings.ini
          case $(${kreadconfig} --file "$gtkSettings" --group Settings --key gtk-theme-name) in
            "" | adw-gtk3 | adw-gtk3-dark)
              ${kwriteconfig} --file "$gtkSettings" --group Settings --key gtk-theme-name ${theme.gtk}
              ;;
          esac
          unset gtkSettings
        fi
      '';
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
