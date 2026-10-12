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
  sharedNiri = sessions.hasSeveralShells cfg "niri";

  # Starts niri with the binds of one shell. niri-session imports this
  # environment into the user manager, where niri reads NIRI_CONFIG and the
  # shell's user services check ORUC_SHELL.
  niriLauncher =
    shell:
    pkgs.writeShellScript "niri-session-${shell}" ''
      export NIRI_CONFIG=/etc/niri/session-${shell}.kdl ORUC_SHELL=${shell}
      exec ${lib.getExe' pkgs.niri "niri-session"}
    '';
  # niri with one display manager session per shell in place of its own.
  niriSessions = pkgs.symlinkJoin {
    name = "niri-sessions";
    paths = [ pkgs.niri ];
    postBuild = ''
      rm $out/share/wayland-sessions/niri.desktop
    ''
    + lib.concatMapStrings (shell: ''
      cat >$out/share/wayland-sessions/niri-${shell}.desktop <<EOF
      [Desktop Entry]
      Name=Niri (${shell})
      Comment=A scrollable-tiling Wayland compositor with the ${shell} shell
      Exec=${niriLauncher shell}
      Type=Application
      DesktopNames=niri
      EOF
    '') niriShells;
    passthru.providedSessions = map (shell: "niri-${shell}") niriShells;
  };
in
{
  config = lib.mkMerge [
    (lib.mkIf (sessions.hasAnyDesktop cfg) {
      services.displayManager = {
        autoLogin.enable = false;
        defaultSession = sessions.defaultSession cfg;
        sddm = {
          enable = true;
          wayland.enable = true;
        };
        plasma-login-manager.enable = false;
      };

      services.greetd.enable = false;
      services.orca.enable = false;
      hardware.graphics.enable = true;
      users.users.oruc.extraGroups = [ "video" ];
      console.colors = map (slot: config.scheme.${slot}) theme.ansi;
    })

    (lib.mkIf hasNiri {
      programs.niri.enable = true;
      programs.niri.package = lib.mkIf sharedNiri niriSessions;
      # niri starts it on demand for X11 applications when it is on the PATH.
      environment.systemPackages = [ pkgs.xwayland-satellite ];
      environment.etc."niri/config.kdl".source = ../niri/config.kdl;
      # Binds for the selected shell, included last by config.kdl so they override
      # the wpctl volume binds. Every niri shell has a file, because niri 26.04
      # treats a missing include as an error. With several shells, each session
      # config adds its shell's binds after config.kdl instead.
      environment.etc."niri/shell.kdl" =
        if sharedNiri then
          { text = "// Each niri session adds its shell's binds in /etc/niri/session-<shell>.kdl.\n"; }
        else
          { source = ../niri/shells + "/${builtins.head niriShells}.kdl"; };
      # The keyboard layout of the greeter, the machine record's touchpad
      # settings, and hardware settings that a machine's modules append;
      # included by config.kdl. niri caches the localed layout at startup, so it
      # writes the layout here instead.
      environment.etc."niri/host.kdl".text = ''
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
      environment.etc."niri/theme.kdl".text =
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
    })

    (lib.mkIf sharedNiri {
      environment.etc = lib.listToAttrs (
        map (
          shell:
          lib.nameValuePair "niri/session-${shell}.kdl" {
            text = ''
              include "/etc/niri/config.kdl"
              include "${../niri/shells + "/${shell}.kdl"}"
            '';
          }
        ) niriShells
      );
    })

    (lib.mkIf hasPlasma {
      services.desktopManager.plasma6.enable = true;
      # Konsole stays for Dolphin's F4 terminal.
      environment.plasma6.excludePackages = with pkgs.kdePackages; [
        elisa
        khelpcenter
      ];
      programs.kde-pim.enable = false;
      environment.systemPackages = [
        # The effect loads only into the exact KWin it was built for. The flake
        # follows our nixpkgs, so both come from the same revision.
        inputs.kwin-effects-better-blur-dx.packages.${pkgs.stdenv.hostPlatform.system}.default
        # Video and Wallpaper Engine wallpapers. Wallpaper Engine scenes need
        # the content from the Steam app.
        pkgs.kdePackages.wallpaper-engine-plugin
      ];
    })
  ];
}
