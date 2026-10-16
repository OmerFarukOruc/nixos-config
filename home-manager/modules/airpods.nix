{ lib, pkgs, ... }:
let
  airpods-tui = pkgs.callPackage ../../pkgs/airpods-tui.nix { };
  # Its OSD default calls swayosd-client, which no session here runs.
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

  # The daemon owns the AirPods control channel; the TUI talks to it over a
  # socket in XDG_RUNTIME_DIR.
  systemd.user.services.airpods-tui = {
    Unit = {
      Description = "AirPods control daemon";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      # The daemon reads its config only at start.
      X-Restart-Triggers = [ "${settingsFile}" ];
    };
    Service = {
      ExecStart = "${lib.getExe airpods-tui} --daemon";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
