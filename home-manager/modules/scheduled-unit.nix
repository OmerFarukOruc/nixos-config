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
  onCalendar ? "daily",
  randomizedDelay ? "1h",
}:
let
  marker = pkgs.writeShellApplication {
    name = "${name}-marker";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./scheduled-unit-marker.sh;
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
      SyslogIdentifier = name;
      Environment = [
        "PATH=/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"
      ];
      TimeoutStartSec = timeout;
    };
  };
  systemd.user.timers.${name} = {
    Unit.Description = timerDescription;
    Timer = {
      OnCalendar = onCalendar;
      Persistent = true;
      RandomizedDelaySec = randomizedDelay;
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
