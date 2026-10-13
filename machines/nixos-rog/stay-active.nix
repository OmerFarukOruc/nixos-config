# Keeps Teams in Brave Available while Omer works on fedora-desktop through
# Deskflow. nixos-rog gets no input then, so KWin counts the session as idle,
# and Teams reads that idle time through Brave's Idle Detection API
# (nixosModules/brave.nix). A virtual mouse moves one pixel and back every
# minute, well inside Teams' five minutes before Away. It moves only on
# weekdays from 09:00 to 18:00. `stay-active off` pauses it until the next
# boot.
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
  # ydotoold owns the virtual input device, and only this unit reaches its
  # socket. Wayland keeps programs from faking input in other windows; putting
  # oruc in the ydotool group would let every program he runs do it.
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

  # oruc starts and stops the unit without a password.
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
