{
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  scheme = osConfig.scheme.withHashtag;
  inherit (osConfig.oruc.theme) fonts wallpaper;
in
{
  config = lib.mkIf (sessions.hasShell osConfig.oruc.machine "waybar") {
    oruc.shellServices = {
      waybar = "waybar";
      mako = "waybar";
    }
    // lib.optionalAttrs (wallpaper != null) { oruc-wallpaper = "waybar"; };
    programs.waybar = {
      enable = true;
      systemd.enable = true;
      settings.mainBar = {
        layer = "top";
        position = "top";
        modules-left = [ "niri/workspaces" ];
        modules-center = [ "clock" ];
        modules-right = [
          "pulseaudio"
          "network"
          "tray"
        ];
        # Explicit formats, so the bar does not depend on the tr_TR date order.
        clock = {
          format = "{:%H:%M}";
          format-alt = "{:%d-%m-%Y %H:%M}";
        };
        tray.spacing = 8;
      };
      style = ''
        * {
          font-family: "${fonts.mono}", "${fonts.ui}", sans-serif;
          font-size: 13px;
          min-height: 0;
        }

        window#waybar {
          background: ${scheme.base00};
          color: ${scheme.base05};
        }

        #workspaces button {
          padding: 0 8px;
          color: ${scheme.base04};
          background: transparent;
          border: none;
          border-radius: 0;
        }

        #workspaces button.focused,
        #workspaces button.active {
          color: ${scheme.base00};
          background: ${scheme.base0D};
        }

        #workspaces button.urgent {
          color: ${scheme.base00};
          background: ${scheme.base08};
        }

        #clock,
        #pulseaudio,
        #network,
        #tray {
          padding: 0 10px;
        }

        #pulseaudio.muted,
        #network.disconnected {
          color: ${scheme.base03};
        }

        tooltip {
          background: ${scheme.base01};
          color: ${scheme.base05};
          border: 1px solid ${scheme.base02};
        }
      '';
    };

    services.mako = {
      enable = true;
      settings = {
        anchor = "top-right";
        background-color = scheme.base00;
        text-color = scheme.base05;
        border-color = scheme.base0D;
        progress-color = "over ${scheme.base02}";
        border-radius = 8;
        border-size = 2;
        default-timeout = 7000;
        font = "${fonts.ui} 11";
        icons = true;
        margin = 12;
        padding = "10,14";
      };
    };

    systemd.user.services.oruc-wallpaper = lib.mkIf (wallpaper != null) {
      Unit = {
        Description = "Base16 desktop wallpaper";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${lib.getExe pkgs.swaybg} -m fill -i ${wallpaper}";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
