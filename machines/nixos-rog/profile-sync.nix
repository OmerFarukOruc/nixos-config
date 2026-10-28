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
      echo "inotifywait ended" >&2
      exit 1
    '';
  };
}
