# Hands a platform profile switch that bypasses power-profiles-daemon, such as
# a click in ROG Control Center or `asusctl profile set`, to the daemon. asusd
# writes /sys/firmware/acpi/platform_profile itself, and power-profiles-daemon
# missed that write: it kept its old profile, governor and EPP, and
# oruc-cpu-limits kept the old profile's limits.
#
# The daemon watches the file's directory inside its own sysfs mount, and that
# watch never fired. This unit watches the file itself in the host's mount.
# When the daemon sets a profile, it writes the file before it answers D-Bus
# calls, so this unit then reads the same profile and sets nothing.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  profiles = import ./power-profiles.nix;
  ppdNames = lib.concatMapStringsSep " " (profile: "[${profile.json}]=${profile.ppd}") profiles;
  file = "/sys/firmware/acpi/platform_profile";
in
{
  systemd.services.oruc-profile-sync = {
    description = "Hand platform profile switches to power-profiles-daemon";
    # power-profiles-daemon starts after multi-user.target, so a unit ordered
    # after the daemon must not be wanted by that target (cpu-limits.nix).
    wantedBy = [ "graphical.target" ];
    requires = [ "power-profiles-daemon.service" ];
    after = [ "power-profiles-daemon.service" ];
    path = [
      config.services.power-profiles-daemon.package
      pkgs.inotify-tools
    ];
    serviceConfig = {
      Restart = "always";
      RestartSec = 5;
    };
    # No sync at start, so a boot or a restart keeps the profile the daemon
    # restored from its state file.
    script = ''
      declare -A ppd=(${ppdNames})
      while read -r _; do
        platform=$(<${file})
        want=''${ppd[$platform]:-}
        if [[ -z $want ]]; then
          echo "unknown platform profile $platform" >&2
        elif [[ $(powerprofilesctl get) != "$want" ]]; then
          powerprofilesctl set "$want"
          echo "$platform: set $want"
        fi
      done < <(inotifywait -m -q -e modify ${file})
      # A module reload removes the file and ends the watch.
      echo "inotifywait ended" >&2
      exit 1
    '';
  };
}
