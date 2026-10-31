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
  theme = config.oruc.theme;
  iconTheme = import ../../nixosModules/icon-theme.nix { inherit lib; };
  hasNiri = sessions.hasDesktop cfg "niri";
  hasPlasma = sessions.hasDesktop cfg "plasma";
  dbusRunSession = "${pkgs.dbus}/bin/dbus-run-session --dbus-daemon=${pkgs.dbus}/bin/dbus-daemon";

  gtkColors =
    { scheme, ... }:
    let
      s = scheme.withHashtag;
    in
    ''
      @define-color accent_color ${s.base0D};
      @define-color accent_bg_color ${s.base0D};
      @define-color accent_fg_color ${s.base00};
      @define-color destructive_color ${s.base08};
      @define-color destructive_bg_color ${s.base08};
      @define-color destructive_fg_color ${s.base00};
      @define-color success_color ${s.base0B};
      @define-color success_bg_color ${s.base0B};
      @define-color success_fg_color ${s.base00};
      @define-color warning_color ${s.base0A};
      @define-color warning_bg_color ${s.base0A};
      @define-color warning_fg_color ${s.base00};
      @define-color error_color ${s.base08};
      @define-color error_bg_color ${s.base08};
      @define-color error_fg_color ${s.base00};
      @define-color window_bg_color ${s.base00};
      @define-color window_fg_color ${s.base05};
      @define-color view_bg_color ${s.base00};
      @define-color view_fg_color ${s.base05};
      @define-color headerbar_bg_color ${s.base01};
      @define-color headerbar_fg_color ${s.base05};
      @define-color headerbar_border_color ${s.base02};
      @define-color headerbar_backdrop_color ${s.base00};
      @define-color card_bg_color ${s.base01};
      @define-color card_fg_color ${s.base05};
      @define-color dialog_bg_color ${s.base01};
      @define-color dialog_fg_color ${s.base05};
      @define-color popover_bg_color ${s.base01};
      @define-color popover_fg_color ${s.base05};
      @define-color sidebar_bg_color ${s.base01};
      @define-color sidebar_fg_color ${s.base05};
      @define-color sidebar_backdrop_color ${s.base00};
      @define-color sidebar_border_color ${s.base02};
      @define-color secondary_sidebar_bg_color ${s.base01};
      @define-color secondary_sidebar_fg_color ${s.base05};
      @define-color thumbnail_bg_color ${s.base01};
      @define-color thumbnail_fg_color ${s.base05};
    '';
  gtkFiles = {
    ".config/gtk-3.0/oruc-colors.css" = gtkColors;
    ".config/gtk-4.0/oruc-colors.css" = gtkColors;
  };
  gtkImport = dir: "@import url(\"file://${config.xdg.configHome}/${dir}/oruc-colors.css\");";

  # Only GTK 3 reads the GTK theme name.
  # GTK 3 on Wayland takes the name from gsettings whenever it sees the
  # org.gnome.desktop.interface schema, which beats settings.ini, so both get
  # it. Without a session bus (a deploy at boot) dconf runs on a private one,
  # as Home Manager's own dconf step does.
  applyPolarity = pkgs.writeShellApplication {
    name = "oruc-polarity";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.dconf
      pkgs.kdePackages.kconfig
      pkgs.kdePackages.plasma-workspace
    ];
    text = ''
      state=${lib.escapeShellArg config.oruc.themeState}
      facts=$state/theme/current/.oruc
      polarity=$(cat "$facts/polarity")
      cursor=$(cat "$facts/cursor")
      icons=$(cat "$facts/icons")
      gtk=$(cat "$facts/gtk")

      dconf_write() {
        if [[ -v DBUS_SESSION_BUS_ADDRESS ]]; then
          dconf write "$@"
        else
          ${dbusRunSession} dconf write "$@"
        fi
      }

      gtk_theme_unless_picked() {
        local settings=${config.xdg.configHome}/gtk-3.0/settings.ini now
        case $(kreadconfig6 --file "$settings" --group Settings --key gtk-theme-name) in
          "" | adw-gtk3 | adw-gtk3-dark)
            kwriteconfig6 --file "$settings" --group Settings --key gtk-theme-name "$gtk"
            ;;
        esac
        now=$(dconf read /org/gnome/desktop/interface/gtk-theme 2>/dev/null) || now=
        case $now in
          "" | "'adw-gtk3'" | "'adw-gtk3-dark'")
            [[ $now == "'$gtk'" ]] || dconf_write /org/gnome/desktop/interface/gtk-theme "'$gtk'"
            ;;
        esac
      }

      icon_theme_unless_picked() {
        local now
        now=$(kreadconfig6 --file kdeglobals --group Icons --key Theme)
        [[ $now != "$icons" ]] || return 0
        case $now in
          "" | ${lib.concatMapStringsSep " | " lib.escapeShellArg iconTheme.replaceable})
            ${pkgs.kdePackages.plasma-workspace}/libexec/plasma-changeicons "$icons"
            ;;
        esac
      }

      force=
      case ''${1:-} in
        --gtk)
          gtk_theme_unless_picked
          exit
          ;;
        --login)
          force=1
          ;;
      esac

      if [[ -n $force || $(cat "$state/theme/polarity" 2>/dev/null) != "$polarity" ]]; then
        plasma-apply-cursortheme "$cursor" --size ${toString theme.cursor.size}
        gtk_theme_unless_picked
        dconf_write /org/gnome/desktop/interface/color-scheme "'prefer-$polarity'"
        printf '%s\n' "$polarity" >"$state/theme/polarity"
      else
        dconf_write /org/gnome/desktop/interface/color-scheme "'default'"
        dconf_write /org/gnome/desktop/interface/color-scheme "'prefer-$polarity'"
      fi
      icon_theme_unless_picked
    '';
  };
in
{
  options.oruc.applyPolarity = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    default = applyPolarity;
    description = "oruc-polarity [--login | --gtk]: on Plasma, gives the session the cursor, GTK theme and color-scheme preference of the stored scheme's dark or light variant when that variant changed or with --login, else toggles the color-scheme preference so GTK 4 apps reload their colours; on every run it gives the session the stored scheme's icon theme unless System Settings picked one outside nixosModules/icon-theme.nix's replaceable names. --gtk sets only the GTK 3 theme name.";
  };

  config = lib.mkMerge [
    (lib.mkIf (hasNiri || hasPlasma) { home.packages = iconTheme.packages pkgs; })

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
        iconTheme.name = theme.icons;
        colorScheme = if theme.isLight then "light" else "dark";
        gtk2.configLocation = "${config.xdg.configHome}/gtk-2.0/gtkrc";
        gtk3.extraCss = gtkImport "gtk-3.0";
        gtk4.extraCss = gtkImport "gtk-4.0";
      };
    })

    (lib.mkIf hasPlasma {
      oruc.themeFacts = {
        cursor = { theme, ... }: theme.cursor.name;
        icons = { theme, ... }: theme.icons;
        gtk = { theme, ... }: theme.gtk;
      };

      home.packages = [
        pkgs.adw-gtk3
        pkgs.bibata-cursors
      ];

      # kde-gtk-config (kded) owns gtk.css and replaces it with a regular file
      # each time it applies a color scheme, so gtk.css cannot be a Home Manager
      # link. It keeps the file's content and only appends its own
      # `@import 'colors.css';`, so the import below survives. Its colors.css
      # defines only names that end in `_breeze`, which do not overlap ours, so
      # the order of the two imports does not matter.
      home.activation.gtkColors = lib.hm.dag.entryAfter [ "writeBoundary" "orucThemePointer" ] ''
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
        fi
        run ${lib.getExe applyPolarity} --gtk || warnEcho "Could not set the GTK 3 theme name."
      '';
    })

    (lib.mkIf (hasPlasma || hasNiri) {
      oruc.themeFiles = gtkFiles;

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
