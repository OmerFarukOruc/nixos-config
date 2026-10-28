{
  config,
  lib,
  pkgs,
  ...
}:
let
  profiles = import ./power-profiles.nix;
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
  bashMap =
    field: lib.concatStringsSep " " (lib.mapAttrsToList (p: l: "[${p}]=${toString l.${field}}") limits);
  restart = "${config.systemd.package}/bin/systemctl restart --no-block oruc-cpu-limits.service";
in
assert lib.assertMsg (
  lib.sort builtins.lessThan (lib.attrNames limits)
  == lib.sort builtins.lessThan (map (profile: profile.ppdName) profiles)
) "CPU limits must use the power-profiles-daemon names in power-profiles.nix.";
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

  powerManagement.resumeCommands = restart;
  services.udev.extraRules = ''
    ACTION=="change", SUBSYSTEM=="power_supply", KERNEL=="ACAD", RUN+="${restart}"
  '';
}
