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
  dconf = lib.getExe pkgs.dconf;
  dbusRunSession = "${pkgs.dbus}/bin/dbus-run-session --dbus-daemon=${pkgs.dbus}/bin/dbus-daemon";

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
  config = lib.mkMerge [
    (lib.mkIf (hasNiri && !hasPlasma) {
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
              { [[ -s $gtkCss ]] && printf '\n'; printf '%s\n' "$gtkImport"; } >>"$gtkCss" ||
                warnEcho "$gtkCss is not writable, so it does not import oruc-colors.css."
            fi
          done
          unset gtkDir gtkCss gtkImport

          # Only GTK 3 reads the theme name. The name is ours while it is unset
          # or already one of adw-gtk3's, so a theme chosen in System Settings
          # stays. GTK 3 on Wayland takes the name from gsettings whenever it
          # sees the org.gnome.desktop.interface schema, which beats
          # settings.ini, so both get it. Without a session bus (a deploy at
          # boot) dconf runs on a private one, as Home Manager's own dconf
          # step does, and a failed write only warns.
          gtkSettings=${config.xdg.configHome}/gtk-3.0/settings.ini
          case $(${kreadconfig} --file "$gtkSettings" --group Settings --key gtk-theme-name) in
            "" | adw-gtk3 | adw-gtk3-dark)
              ${kwriteconfig} --file "$gtkSettings" --group Settings --key gtk-theme-name ${theme.gtk}
              ;;
          esac
          unset gtkSettings

          gtkThemeKey=/org/gnome/desktop/interface/gtk-theme
          gtkThemeNow=$(${dconf} read "$gtkThemeKey" 2>/dev/null) || gtkThemeNow=
          case $gtkThemeNow in
            "" | "'adw-gtk3'" | "'adw-gtk3-dark'")
              if [[ $gtkThemeNow != "'${theme.gtk}'" ]]; then
                if [[ -v DBUS_SESSION_BUS_ADDRESS ]]; then
                  dconfBus=()
                else
                  dconfBus=(${dbusRunSession})
                fi
                run "''${dconfBus[@]}" ${dconf} write "$gtkThemeKey" "'${theme.gtk}'" ||
                  warnEcho "Could not set the GTK 3 theme in dconf."
                unset dconfBus
              fi
              ;;
          esac
          unset gtkThemeKey gtkThemeNow
        fi
      '';
    })

    (lib.mkIf (hasPlasma || hasNiri) {
      # GTK's automatic font rendering at a fractional scale drops the top pixel
      # row of Inter at libadwaita's caption size (82 %) under the GL and Vulkan
      # renderers (observed 2026-10-26 with GTK 4.22.4). Manual follows the
      # desktop's hinting and antialiasing instead. GTK on Wayland reads it
      # through the settings portal, which ignores gtk-4.0/settings.ini.
      dconf.settings."org/gnome/desktop/interface".font-rendering = "manual";
    })

    (lib.mkIf hasNiri {
      qt = {
        enable = true;
        platformTheme.name = "kde";
      };
    })
  ];
}
