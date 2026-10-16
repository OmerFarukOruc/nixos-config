# Exec lines that let a unit that changes the look run once per Plasma login.
# Home Manager starts each inactive unit that an active target wants at every
# switch, and a live color scheme change crashed Discord (an Electron app) on
# 2026-10-16. The unit stores the invocation ID of plasma-workspace.target,
# which each login renews, and skips a start that finds the same ID. Each
# activation also writes the running login's ID (markPlasmaLogin in
# default.nix), whose unit list names every unit that uses this file.
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
  # ExecCondition of the unit.
  condition = "${newLogin} ${marker}";
  # The last ExecStartPost of the unit, so a failed start leaves no mark.
  mark = "${markLogin} ${marker}";
}
