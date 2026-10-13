# Per-profile CPU limits on top of the power limits in asus.nix: a temperature
# at which the CPU throttles itself, and a top clock. Nothing else sets either,
# so this unit writes them at start, after each power-profiles-daemon profile
# change, after resume, and when the charger is plugged in or out.
#
# The temperature limit lives in the SMU (the chip's power controller) and is
# lost at reboot; ryzenadj writes it through ryzen_smu (apps.nix). It survives
# a profile switch and an asusd restart, but an s2idle resume resets it to
# 95 °C. A sleep that bypasses systemd, such as rtcwake, runs no resume
# command, so the unit also checks both limits every 30 s.
#
# power-profiles-daemon turns boost off in power-saver, which asusd calls quiet,
# so power-saver needs no clock cap. One busy thread at 5.1 GHz held the CPU at
# 74 °C and spun the fans up; at 4.0 GHz it stayed at 56 °C with the fans at
# their floor.
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
    # power-profiles-daemon starts after multi-user.target, so a unit ordered
    # after the daemon must not be wanted by that target, or the boot would wait
    # on a cycle and never reach it.
    wantedBy = [ "graphical.target" ];
    requires = [ "power-profiles-daemon.service" ];
    after = [ "power-profiles-daemon.service" ];
    path = [
      config.services.power-profiles-daemon.package
      pkgs.gawk
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

      # Applies the limits again when the SMU or policy0 lost them.
      check() {
        local profile temp max
        profile=$(powerprofilesctl get)
        max=''${tops[$profile]}
        temp=$(ryzenadj -i | awk -F'|' '/THM LIMIT CORE/ {printf "%d", $3}')
        [[ $max == top ]] && max=$(</sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq)
        if [[ $temp != "''${temps[$profile]}" || $(</sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq) != "$max" ]]; then
          apply "$profile"
        fi
      }

      profile=$(powerprofilesctl get)
      apply "$profile"
      # One line per property change; only ActiveProfile changes matter.
      active="'ActiveProfile': <'([a-z-]+)'>"
      while true; do
        if read -r -t 30 line; then
          if [[ $line =~ $active ]]; then
            apply "''${BASH_REMATCH[1]}"
          fi
        elif (($? > 128)); then
          check
        else
          echo "gdbus monitor ended" >&2
          exit 1
        fi
      done < <(gdbus monitor --system --dest org.freedesktop.UPower.PowerProfiles \
        --object-path /org/freedesktop/UPower/PowerProfiles)
    '';
  };

  # A restart applies the limits again.
  powerManagement.resumeCommands = restart;
  services.udev.extraRules = ''
    ACTION=="change", SUBSYSTEM=="power_supply", KERNEL=="ACAD", RUN+="${restart}"
  '';
}
