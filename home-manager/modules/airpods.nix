{ lib, pkgs, ... }:
let
  airpods-tui = pkgs.callPackage ../../pkgs/airpods-tui.nix { };
  settingsFile = (pkgs.formats.toml { }).generate "airpods-tui.toml" {
    volume_osd_command = [ ];
    volume_set_command = [
      (lib.getExe' pkgs.wireplumber "wpctl")
      "set-volume"
      "@DEFAULT_AUDIO_SINK@"
      "{}"
    ];
    battery_alert_command = [
      (lib.getExe' pkgs.libnotify "notify-send")
      "AirPods"
      "{}"
    ];
  };
in
{
  home.packages = [ airpods-tui ];

  xdg.configFile."airpods-tui/config.toml".source = settingsFile;

  systemd.user.services.airpods-tui = {
    Unit = {
      Description = "AirPods control daemon";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      X-Restart-Triggers = [ "${settingsFile}" ];
      StartLimitIntervalSec = 60;
      StartLimitBurst = 3;
    };
    Service = {
      ExecStart = "${lib.getExe airpods-tui} --daemon";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
