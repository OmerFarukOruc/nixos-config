# The macOS Tahoe look from lestercorderomurillo/macos-tahoe-liquid-kde: its
# Plasma style, Aurorae decoration, Kvantum style, colors, icons and cursor,
# the Acrylic Glass and rounded corner KWin effects, a top bar with the global
# menu and a dock. Its own theme switcher, mac-tahoe-theme.service, applies them
# at login; the upstream README marks its NixOS modules as testing.
{
  config,
  inputs,
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  isPlasma = sessions.hasDesktop osConfig.oruc.machine "plasma";
  active = config.oruc.plasma.look == "tahoe";
  tahoe = inputs.mac-tahoe.lib.mkPackages pkgs;
  themeOnce = import ./once-per-login.nix { inherit lib pkgs; } "mac-tahoe-theme";
  kreadconfig = lib.getExe' pkgs.kdePackages.kconfig "kreadconfig6";
  kwriteconfig = lib.getExe' pkgs.kdePackages.kconfig "kwriteconfig6";
  dconf = lib.getExe pkgs.dconf;
  plasmaGtkCss = pkgs.writeText "gtk.css" "@import 'colors.css';";

  # The theme assets without their copy of Panel Colorizer, which the profile
  # already holds. Each widget stays one directory link, because Plasma
  # rejects a widget whose files link into another directory ("Path traversal
  # attempt detected"), as Home Manager's file-by-file links in
  # ~/.local/share and the upstream package's symlinkJoin do.
  tahoeShare = pkgs.runCommandLocal "mac-tahoe-share" { } ''
    src=${tahoe.theme-assets}/share
    mkdir -p $out/share/plasma/plasmoids
    for d in "$src"/*; do
      [[ ''${d##*/} == plasma ]] || ln -s "$d" $out/share/
    done
    for d in "$src"/plasma/*; do
      [[ ''${d##*/} == plasmoids ]] || ln -s "$d" $out/share/plasma/
    done
    for d in "$src"/plasma/plasmoids/*; do
      [[ ''${d##*/} == luisbocanegra.panel.colorizer ]] || ln -s "$d" $out/share/plasma/plasmoids/
    done
  '';
in
{
  imports = [
    inputs.mac-tahoe.homeManagerModules.default
    inputs.mac-tahoe.homeManagerModules.plasma-manager
  ];

  config = lib.mkIf isPlasma (
    lib.mkMerge [
      {
        # The look's own module installs these only in its generation, which
        # is a specialisation, so they are installed here, named one by one so
        # that ci/cached-packages.nix finds the compiled ones.
        home.packages = with tahoe; [
          tahoeShare
          global-menu
          task-manager
          acrylic-glass
          rounded-corners
          tools
          pkgs.kdePackages.qtstyleplugin-kvantum
        ];
        # Acrylic Glass replaces the built-in blur.
        programs.plasma.configFile.kwinrc.Plugins = {
          liquidglassEnabled = active;
          shapecornersEnabled = active;
        };
      }

      (lib.mkIf active {
        oruc.plasma = {
          colorScheme = null;
          widgetStyle = null;
          panelLayout = "none";
        };

        programs.mac-tahoe = {
          enable = true;
          mode = if osConfig.oruc.theme.isLight then "light" else "dark";
          panels = {
            enable = true;
            launchers = config.oruc.plasma.dockLaunchers;
          };
        };

        # The upstream module links the theme assets into ~/.local/share file
        # by file and adds a session script that puts its package first in
        # XDG_DATA_DIRS, so Plasma rejects every Tahoe widget; tahoeShare holds
        # them instead. Its session variables replace QT_PLUGIN_PATH and
        # QML2_IMPORT_PATH with its own plugins, which drops Plasma's QML
        # modules and leaves an empty desktop. The profile already holds those
        # plugins, so the variables keep the value they had.
        xdg.dataFile =
          lib.genAttrs
            [
              "plasma/desktoptheme"
              "plasma/look-and-feel"
              "plasma/plasmoids"
              "aurorae/themes"
              "color-schemes"
              "icons"
            ]
            (_: {
              enable = lib.mkForce false;
            });
        xdg.configFile."plasma-workspace/env/mac-tahoe-plugin-paths.sh".enable = lib.mkForce false;
        home.sessionVariables = {
          QT_PLUGIN_PATH = lib.mkForce "$QT_PLUGIN_PATH";
          QML2_IMPORT_PATH = lib.mkForce "$QML2_IMPORT_PATH";
        };

        # The theme switcher sets the cursor, icons, splash and title bar
        # buttons, so plasma-manager leaves them alone in this look.
        programs.plasma = {
          workspace = {
            cursor.theme = lib.mkForce null;
            iconTheme = lib.mkForce null;
            splashScreen.theme = lib.mkForce null;
          };
          # The value the theme switcher writes.
          configFile.kwinrc."org.kde.kdecoration2".BorderSize = lib.mkForce "Tiny";
          kwin = {
            effects.blur.enable = false;
            titlebarButtons = {
              left = lib.mkForce null;
              right = lib.mkForce null;
            };
          };
        };

        # The unit starts after plasma-workspace.target, so the condition reads
        # this login's invocation ID; started with plasmashell, it read the
        # last login's ID and skipped.
        systemd.user.services.mac-tahoe-theme = {
          Service = {
            ExecCondition = themeOnce.condition;
            ExecStartPost = themeOnce.mark;
          };
          Unit = {
            Description = lib.mkForce "Apply the macOS Tahoe look once per Plasma login";
            After = [ "plasma-workspace.target" ];
            PartOf = lib.mkForce [ "plasma-workspace.target" ];
          };
          Install.WantedBy = lib.mkForce [ "plasma-workspace.target" ];
        };
      })

      # The theme switcher points GTK at its own theme and copies its GTK 4
      # stylesheet and assets, which outlast the look. When another look is
      # stored, this puts back what Plasma writes. It skips the activation of the
      # default look that comes before a stored Tahoe look on each deploy, and
      # it acts only on Tahoe's traces. A failed step warns instead of failing
      # the activation, which would roll back a deploy.
      (lib.mkIf (!active) {
        home.activation.leaveTahoe = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          leaveTahoe() {
            local gtk4=$HOME/.config/gtk-4.0 settings
            if [[ $(cat "${config.xdg.stateHome}/oruc/plasma-look" 2>/dev/null) == tahoe ]]; then
              return 0
            fi
            if [[ -L $gtk4/gtk.css && $(readlink "$gtk4/gtk.css") == gtk-*.css ]]; then
              # The copies keep the read-only mode of the store files.
              run chmod -R u+w "$gtk4/assets" "$gtk4/windows-assets" 2>/dev/null || true
              run rm -rf "$gtk4/gtk.css" "$gtk4/gtk-Dark.css" "$gtk4/gtk-Light.css" \
                "$gtk4/assets" "$gtk4/windows-assets" || return 1
              run install -m 644 ${plasmaGtkCss} "$gtk4/gtk.css" || return 1
            fi
            for settings in "$HOME/.config/gtk-3.0/settings.ini" "$gtk4/settings.ini"; do
              if [[ $(${kreadconfig} --file "$settings" --group Settings --key gtk-theme-name) == MacTahoe* ]]; then
                run ${kwriteconfig} --file "$settings" --group Settings --key gtk-theme-name --delete || return 1
              fi
            done
            if [[ -f $HOME/.gtkrc-2.0 ]] && grep -q '^gtk-theme-name="MacTahoe' "$HOME/.gtkrc-2.0"; then
              run sed -i '/^gtk-theme-name="MacTahoe/d' "$HOME/.gtkrc-2.0" || return 1
            fi
            if [[ $(${kreadconfig} --file kdeglobals --group KDE --key LookAndFeelPackage) == *mac-tahoe* ]]; then
              run ${kwriteconfig} --file kdeglobals --group KDE --key LookAndFeelPackage --delete || return 1
            fi
            # dconf writes through the session bus, which a boot has not started.
            if [[ $(${dconf} read /org/gnome/desktop/interface/gtk-theme 2>/dev/null) == *MacTahoe* ]]; then
              run ${dconf} reset /org/gnome/desktop/interface/gtk-theme || return 1
            fi
            if [[ $(${dconf} read /org/gnome/desktop/wm/preferences/button-layout 2>/dev/null) == "'close,minimize,maximize:'" ]]; then
              run ${dconf} reset /org/gnome/desktop/wm/preferences/button-layout || return 1
            fi
          }
          leaveTahoe || warnEcho "Some of the Tahoe look's GTK settings stayed; run plasma-look again in the Plasma session."
        '';
      })
    ]
  );
}
