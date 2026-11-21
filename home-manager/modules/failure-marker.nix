{ lib, pkgs }:
name: hint:
let
  marker = pkgs.writeShellApplication {
    name = "${name}-marker";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = builtins.readFile ./scheduled-unit-marker.sh;
  };
  markerFile = "\${XDG_STATE_HOME:-$HOME/.local/state}/${name}/failed";
  stopPost = "${marker}/bin/${name}-marker ${lib.escapeShellArg hint}";
in
{
  execStopPost = stopPost;
  rerun = {
    execStopPost = "${stopPost} --rerun";
    service = {
      Unit = {
        Description = "Start ${name} again when a shutdown stopped its last run";
        ConditionPathExists = "%S/${name}/rerun";
      };
      Service = {
        Type = "oneshot";
        ExecStart = [
          "${pkgs.coreutils}/bin/rm -f %S/${name}/rerun"
          "${pkgs.systemd}/bin/systemctl --user start --no-block ${name}.service"
        ];
      };
    };
    timer = {
      Unit.Description = "Check after each start of the user manager whether a shutdown stopped ${name}";
      Timer.OnStartupSec = "5min";
      Install.WantedBy = [ "timers.target" ];
    };
  };
  initContent = ''
    if [[ -r ${markerFile} ]]; then
      print -r -- "${name}: $(<${markerFile})"
    fi
  '';
}
