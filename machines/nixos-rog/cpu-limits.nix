# Per-profile CPU limits on top of the power limits in asus.nix: a temperature
# at which the CPU throttles itself, and a top clock. Nothing else sets either,
# so this unit writes them at start, after each power-profiles-daemon profile
# change, after resume, and when the charger is plugged in or out.
#
# The temperature limit lives in the SMU (the chip's power controller) and is
# lost at reboot; ryzenadj writes it through ryzen_smu (apps.nix). It survives
# a profile switch and an asusd restart. power-profiles-daemon turns boost off
# in power-saver, so quiet needs no clock cap. One busy thread at 5.1 GHz held
# the CPU at 74 °C and spun the fans up; at 4.0 GHz it stayed at 56 °C with
# the fans at their floor.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Keyed by power-profiles-daemon profile. maxKHz = "top" keeps each core's
  # own top clock; the Zen 5c cores stop at 3.29 GHz below any cap here.
  limits = {
    power-saver = {
      tempC = 70;
      maxKHz = "top";
    };
    balanced = {
      tempC = 80;
      maxKHz = 4000000;
    };
    performance = {
      tempC = 85;
      maxKHz = "top";
    };
  };
  # A bash associative array from profile to the value of field.
  bashMap =
    field: lib.concatStringsSep " " (lib.mapAttrsToList (p: l: "[${p}]=${toString l.${field}}") limits);
  restart = "${config.systemd.package}/bin/systemctl restart --no-block oruc-cpu-limits.service";
in
{
  oruc.verifyFacts = lib.concatMapAttrs (
    profile: limit:
    let
      key = lib.replaceStrings [ "-" ] [ "_" ] profile;
    in
    {
      "cpu_temp_limit_${key}" = toString limit.tempC;
      "cpu_max_khz_${key}" = toString limit.maxKHz;
    }
  ) limits;

  systemd.services.oruc-cpu-limits = {
    description = "Set the CPU temperature limit and top clock of the power profile";
    wantedBy = [ "multi-user.target" ];
    requires = [ "power-profiles-daemon.service" ];
    after = [ "power-profiles-daemon.service" ];
    path = [
      config.services.power-profiles-daemon.package
      pkgs.glib.bin
      pkgs.ryzenadj
    ];
    # A lasting fault, such as ryzenadj failing, fails the unit after 5 tries.
    startLimitIntervalSec = 60;
    startLimitBurst = 5;
    serviceConfig = {
      Restart = "always";
      RestartSec = 5;
    };
    script = ''
      declare -A temps=(${bashMap "tempC"}) tops=(${bashMap "maxKHz"})
      apply() {
        local temp=''${temps[$1]} max=''${tops[$1]} policy khz
        ryzenadj --tctl-temp="$temp" >/dev/null
        for policy in /sys/devices/system/cpu/cpufreq/policy*; do
          khz=$max
          [[ $max == top ]] && khz=$(<"$policy/cpuinfo_max_freq")
          echo "$khz" >"$policy/scaling_max_freq"
        done
        echo "$1: $temp °C, top clock $max"
      }

      apply "$(powerprofilesctl get)"
      # One line per property change; only ActiveProfile changes matter.
      active="'ActiveProfile': <'([a-z-]+)'>"
      gdbus monitor --system --dest org.freedesktop.UPower.PowerProfiles \
        --object-path /org/freedesktop/UPower/PowerProfiles |
        while read -r line; do
          if [[ $line =~ $active ]]; then
            apply "''${BASH_REMATCH[1]}"
          fi
        done
    '';
  };

  # A restart applies the limits again.
  powerManagement.resumeCommands = restart;
  services.udev.extraRules = ''
    ACTION=="change", SUBSYSTEM=="power_supply", KERNEL=="ACAD", RUN+="${restart}"
  '';
}
