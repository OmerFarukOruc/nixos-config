{ lib, pkgs }:
name:
let
  systemctl = lib.getExe' pkgs.systemd "systemctl";
  marker = "%t/${name}.login";
  newLogin = pkgs.writeShellScript "${name}-new-login" ''
    login=$(${systemctl} --user show -p InvocationID --value plasma-workspace.target)
    [[ -n $login && $(cat "$1" 2>/dev/null) != "$login" ]]
  '';
  markLogin = pkgs.writeShellScript "${name}-mark-login" ''
    ${systemctl} --user show -p InvocationID --value plasma-workspace.target >"$1"
  '';
in
{
  condition = "${newLogin} ${marker}";
  mark = "${markLogin} ${marker}";
}
