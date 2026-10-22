{
  config,
  inputs,
  lib,
  pkgs,
  sessions,
  ...
}:
let
  cfg = config.oruc.machine;
  theme = config.oruc.theme;
  hasNiri = sessions.hasDesktop cfg "niri";
  hasPlasma = sessions.hasDesktop cfg "plasma";
  niriShells = sessions.shellsOf cfg "niri";
  niriSessionName =
    shell:
    sessions.sessionName cfg {
      desktop = "niri";
      inherit shell;
    };

  # Starts niri with that shell's binds. niri-session imports this environment
  # into the user manager, where niri reads NIRI_CONFIG. A desktop with several
  # shells also sets ORUC_SHELL, which those shells' services check.
  niriLauncher =
    shell:
    pkgs.writeShellScript "niri-session-${shell}" ''
      export NIRI_CONFIG=/etc/niri/${niriSessionName shell}.kdl
      ${lib.optionalString (sessions.hasSeveralShells cfg "niri") "export ORUC_SHELL=${shell}"}
      exec ${lib.getExe' pkgs.niri "niri-session"}
    '';
  # One display manager session per niri shell, named by sessions.sessionName.
  # With one shell that name is niri, so the stock desktop file is replaced.
  niriSessions = pkgs.symlinkJoin {
    name = "niri-sessions";
    paths = [ pkgs.niri ];
    postBuild =
      lib.optionalString (!lib.elem "niri" (map niriSessionName niriShells)) ''
        rm $out/share/wayland-sessions/niri.desktop
      ''
      + lib.concatMapStrings (shell: ''
        rm -f $out/share/wayland-sessions/${niriSessionName shell}.desktop
        cat >$out/share/wayland-sessions/${niriSessionName shell}.desktop <<EOF
        [Desktop Entry]
        Name=Niri (${shell})
        Comment=A scrollable-tiling Wayland compositor with the ${shell} shell
        Exec=${niriLauncher shell}
        Type=Application
        DesktopNames=niri
        EOF
      '') niriShells;
    passthru.providedSessions = map niriSessionName niriShells;
  };
in
{
  config = lib.mkMerge [
    (lib.mkIf (sessions.hasAnyDesktop cfg) {
      services.displayManager = {
        # Off unless the machine record turns it on; plasma-manager.nix then
        # starts the session locked.
        autoLogin = {
          enable = cfg.autoLogin;
          user = lib.mkIf cfg.autoLogin "oruc";
        };
        defaultSession = sessions.defaultSession cfg;
        sddm = {
          enable = true;
          wayland.enable = true;
        };
        plasma-login-manager.enable = false;
      };

      services.greetd.enable = false;
      # Puts the Qt plugins and QML modules of the system profile on each
      # session's search path.
      qt.enable = true;
      services.orca.enable = false;
      hardware.graphics.enable = true;
      users.users.oruc.extraGroups = [ "video" ];
      console.colors = map (slot: config.scheme.${slot}) theme.ansi;
    })

    (lib.mkIf hasNiri {
      programs.niri.enable = true;
      programs.niri.package = niriSessions;
      # niri starts it on demand for X11 applications when it is on the PATH.
      environment.systemPackages = [ pkgs.xwayland-satellite ];
      environment.etc = lib.mkMerge [
        {
          "niri/config.kdl".source = ../niri/config.kdl;
          # config.kdl includes this. The session file adds the shell's binds
          # after config.kdl, so the stub stays a comment for one shell and for several.
          "niri/shell.kdl".text = ''
            // The session file adds this shell's binds after config.kdl.
          '';
          # The keyboard layout of the greeter, the machine record's touchpad
          # settings, and hardware settings that a machine's modules append;
          # included by config.kdl. niri caches the localed layout at startup, so it
          # writes the layout here instead.
          "niri/host.kdl".text = ''
            // Settings for this machine's hardware.
            input {
                keyboard {
                    xkb {
                        layout "${config.services.xserver.xkb.layout}"
                    }
                }
                touchpad {
                    ${lib.optionalString cfg.touchpad.tapToClick "tap"}
                    ${lib.optionalString cfg.touchpad.naturalScroll "natural-scroll"}
                }
            }
          '';
          # Colors for the compositor, included by config.kdl.
          "niri/theme.kdl".text =
            let
              scheme = config.scheme.withHashtag;
            in
            ''
              layout {
                  focus-ring {
                      active-color "${scheme.base0D}"
                      inactive-color "${scheme.base03}"
                      urgent-color "${scheme.base08}"
                  }
                  border {
                      active-color "${scheme.base0D}"
                      inactive-color "${scheme.base03}"
                      urgent-color "${scheme.base08}"
                  }
                  insert-hint {
                      color "${scheme.base0D}80"
                  }
              }

              overview {
                  backdrop-color "${scheme.base00}"
              }

              cursor {
                  xcursor-theme "${theme.cursor.name}"
                  xcursor-size ${toString theme.cursor.size}
              }
            '';
        }
        (lib.listToAttrs (
          map (
            shell:
            lib.nameValuePair "niri/${niriSessionName shell}.kdl" {
              text = ''
                include "/etc/niri/config.kdl"
                include "${../niri/shells + "/${shell}.kdl"}"
              '';
            }
          ) niriShells
        ))
      ];
    })

    (lib.mkIf hasPlasma {
      services.desktopManager.plasma6.enable = true;
      nixpkgs.overlays = [ (import ../overlays/ksystemstats.nix) ];
      # Konsole stays for Dolphin's F4 terminal.
      environment.plasma6.excludePackages = with pkgs.kdePackages; [
        elisa
        khelpcenter
      ];
      programs.kde-pim.enable = false;
      environment.systemPackages = [
        # The effect loads only into the exact KWin it was built for. The flake
        # follows our nixpkgs, so both come from the same revision.
        inputs.kwin-effects-glass.packages.${pkgs.stdenv.hostPlatform.system}.default
        # The Glass Qt 6 style and window decoration, built the same way.
        inputs.glass-style.packages.${pkgs.stdenv.hostPlatform.system}.glass-qt6
        # Video and Wallpaper Engine wallpapers. Wallpaper Engine scenes need
        # the content from the Steam app.
        pkgs.kdePackages.wallpaper-engine-plugin
      ];
    })
  ];
}
