{ lib, pkgs }:
{ name, target }:
let
  systemctl = lib.getExe' pkgs.systemd "systemctl";
  newLogin = pkgs.writeShellScript "${name}-new-login" ''
    login=$(${systemctl} --user show -p InvocationID --value ${target})
    [[ -n $login && $(cat "$1" 2>/dev/null) != "$login" ]]
  '';
  markLogin = pkgs.writeShellScript "${name}-mark-login" ''
    ${systemctl} --user show -p InvocationID --value ${target} >"$1"
  '';
in
{
  condition = "${newLogin} %t/${name}.login";
  mark = "${markLogin} %t/${name}.login";
  markIn = dir: "${markLogin} ${dir}/${name}.login";
}
