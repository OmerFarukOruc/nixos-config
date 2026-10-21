# The low-battery power profile on rog.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  ppd = lib.getExe config.services.power-profiles-daemon.package;
  lowBatteryPercent = 20;
in
{
  oruc.verifyFacts.low_battery_percent = toString lowBatteryPercent;

  # Drops to power-saver at or below lowBatteryPercent on battery, and returns
  # to balanced on AC if this unit made the drop.
  systemd.services.oruc-low-battery = {
    description = "Switch power-profiles-daemon to power-saver on low battery";
    after = [ "power-profiles-daemon.service" ];
    requires = [ "power-profiles-daemon.service" ];
    serviceConfig = {
      Type = "oneshot";
      RuntimeDirectory = "oruc-low-battery";
      RuntimeDirectoryPreserve = true;
    };
    script = ''
      marker=/run/oruc-low-battery/active
      online=$(cat /sys/class/power_supply/ACAD/online)
      capacity=$(cat /sys/class/power_supply/BAT1/capacity)
      if [[ $online == 0 && $capacity -le ${toString lowBatteryPercent} ]]; then
        if [[ $(${ppd} get) != power-saver ]]; then
          # The marker is written first. A stop before the profile change
          # leaves the marker and the old profile, and the next run finishes
          # the change. Setting the profile on every later run would make
          # asusd rewrite the fan curves and drop a thermal-test override.
          touch "$marker"
          ${ppd} set power-saver
        fi
      elif [[ $online == 1 && -e $marker ]]; then
        # A marker with any other profile means the change never landed, so
        # there is nothing to undo.
        if [[ $(${ppd} get) == power-saver ]]; then
          ${ppd} set balanced
        fi
        rm -f "$marker"
      fi
    '';
  };
  systemd.timers.oruc-low-battery = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
      # Lets the wakeup coalesce with others on battery.
      AccuracySec = "1min";
    };
  };
  # React to plugging and unplugging at once instead of on the next tick.
  services.udev.extraRules = ''
    ACTION=="change", SUBSYSTEM=="power_supply", KERNEL=="ACAD", RUN+="${pkgs.systemd}/bin/systemctl start --no-block oruc-low-battery.service"
  '';
}
