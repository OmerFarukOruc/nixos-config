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
  failure = import ./failure-marker.nix { inherit lib pkgs; } name hint;
in
{
  programs.zsh.initContent = failure.initContent;

  systemd.user.services.${name} = {
    Unit.Description = description;
    Service = {
      Type = "oneshot";
      ExecStart = execStart;
      ExecStopPost = [ failure.execStopPost ] ++ stopPost;
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
