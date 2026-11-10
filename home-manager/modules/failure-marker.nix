{ lib, pkgs }:
name: hint:
let
  marker = pkgs.writeShellApplication {
    name = "${name}-marker";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./scheduled-unit-marker.sh;
  };
  markerFile = "\${XDG_STATE_HOME:-$HOME/.local/state}/${name}/failed";
in
{
  execStopPost = "${marker}/bin/${name}-marker ${lib.escapeShellArg hint}";
  initContent = ''
    if [[ -r ${markerFile} ]]; then
      print -r -- "${name}: $(<${markerFile})"
    fi
  '';
}
