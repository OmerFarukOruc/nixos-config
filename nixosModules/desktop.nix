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

  niriLauncher =
    shell:
    pkgs.writeShellScript "niri-session-${shell}" ''
      export NIRI_CONFIG=/etc/niri/${niriSessionName shell}.kdl
      ${lib.optionalString (sessions.hasSeveralShells cfg "niri") "export ORUC_SHELL=${shell}"}
      exec ${lib.getExe' pkgs.niri "niri-session"}
    '';
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
        autoLogin = {
          enable = cfg.autoLogin;
          user = lib.mkIf cfg.autoLogin cfg.user;
        };
        defaultSession = sessions.defaultSession cfg;
        sddm = {
          enable = true;
          wayland.enable = true;
        };
        plasma-login-manager.enable = false;
      };

      services.greetd.enable = false;
      qt.enable = true;
      services.orca.enable = false;
      hardware.graphics.enable = true;
      users.users.${cfg.user}.extraGroups = [ "video" ];
      console.colors = map (slot: config.scheme.${slot}) theme.ansi;
    })

    (lib.mkIf hasNiri {
      programs.niri.enable = true;
      programs.niri.package = niriSessions;
      environment.systemPackages = [ pkgs.xwayland-satellite ];
      environment.etc = lib.mkMerge [
        {
          "niri/config.kdl".source = ../niri/config.kdl;
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
          "niri/theme.kdl".text = import ./niri-theme.nix {
            inherit (config) scheme;
            inherit theme;
          };
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
      nixpkgs.overlays = [
        (import ../overlays/ksystemstats.nix)
        (import ../overlays/plasma-desktop.nix)
      ];
      environment.plasma6.excludePackages = with pkgs.kdePackages; [
        elisa
        khelpcenter
      ];
      programs.kde-pim.enable = false;
      services.gnome.gcr-ssh-agent.enable = true;
      environment.systemPackages = [
        # The effect loads only into the exact KWin it was built for. The flake
        # follows our nixpkgs, so both come from the same revision.
        inputs.kwin-effects-glass.packages.${pkgs.stdenv.hostPlatform.system}.default
        inputs.glass-style.packages.${pkgs.stdenv.hostPlatform.system}.glass-qt6
        pkgs.kdePackages.wallpaper-engine-plugin
        pkgs.kdotool
        pkgs.libsecret
      ];
    })
  ];
}
