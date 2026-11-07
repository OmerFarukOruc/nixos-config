{
  config,
  lib,
  pkgs,
}:
{
  name,
  description,
  timerDescription,
  execStart,
  timeout,
  hint,
  stopPost ? [ ],
}:
let
  marker = pkgs.writeShellApplication {
    name = "${name}-marker";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./daily-unit-marker.sh;
  };
  markerFile = "\${XDG_STATE_HOME:-$HOME/.local/state}/${name}/failed";
in
{
  programs.zsh.initContent = ''
    if [[ -r ${markerFile} ]]; then
      print -r -- "${name}: $(<${markerFile})"
    fi
  '';

  systemd.user.services.${name} = {
    Unit.Description = description;
    Service = {
      Type = "oneshot";
      ExecStart = execStart;
      ExecStopPost = [ "${marker}/bin/${name}-marker ${lib.escapeShellArg hint}" ] ++ stopPost;
      StateDirectory = name;
      Environment = [
        "PATH=/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"
      ];
      TimeoutStartSec = timeout;
    };
  };
  systemd.user.timers.${name} = {
    Unit.Description = timerDescription;
    Timer = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
