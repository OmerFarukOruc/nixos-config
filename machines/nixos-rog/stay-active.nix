{ config, pkgs, ... }:
let
  unit = "oruc-stay-active.service";
  stayActive = pkgs.writeShellApplication {
    name = "stay-active";
    text = ''
      case ''${1:-status} in
        on) systemctl start ${unit} ;;
        off) systemctl stop ${unit} ;;
        status) systemctl is-active ${unit} ;;
        *)
          echo "usage: stay-active [on|off|status]" >&2
          exit 64
          ;;
      esac
    '';
  };
in
{
  programs.ydotool.enable = true;

  environment.systemPackages = [ stayActive ];

  systemd.services.oruc-stay-active = {
    description = "Move the pointer one pixel and back every minute in working hours";
    wantedBy = [ "multi-user.target" ];
    requires = [ "ydotoold.service" ];
    after = [ "ydotoold.service" ];
    path = [ pkgs.ydotool ];
    environment.YDOTOOL_SOCKET = config.environment.variables.YDOTOOL_SOCKET;
    serviceConfig = {
      DynamicUser = true;
      SupplementaryGroups = [ config.programs.ydotool.group ];
      # ydotoold reports started before it creates its socket, so the first
      # move after boot can fail. A restart also starts a stopped ydotoold
      # through `requires`. RestartSec keeps the restarts under systemd's
      # default limit of 5 starts in 10 seconds.
      Restart = "on-failure";
      RestartSec = 10;
    };
    script = ''
      while true; do
        now=$((10#$(date +%H%M)))
        if (($(date +%u) <= 5 && now >= 900 && now < 1800)); then
          ydotool mousemove -x 1 -y 0
          ydotool mousemove -x -1 -y 0
        fi
        sleep 60
      done
    '';
  };

  security.polkit.extraConfig = ''
    polkit.addRule(function (action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          action.lookup("unit") == "${unit}" &&
          subject.user == "oruc" &&
          ["start", "stop"].indexOf(action.lookup("verb")) >= 0) {
        return polkit.Result.YES;
      }
    });
  '';
}
