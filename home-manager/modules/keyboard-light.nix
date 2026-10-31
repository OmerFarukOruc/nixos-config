{ setColour, ready }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  apply = pkgs.writeShellApplication {
    name = "oruc-keyboard-light";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      for _ in $(seq 30); do
        ${ready} && break
        sleep 1
      done
      colour=$(<${lib.escapeShellArg "${config.oruc.themeFactsDir}/keyboard-light"})
      timeout 20 ${setColour "\"$colour\""}
    '';
  };
in
{
  oruc.themeFacts.keyboard-light = { scheme, ... }: scheme.base09;

  oruc.variantReloads.keyboard-light = ''
    systemctl --user is-active -q graphical-session.target || exit 0
    systemctl --user restart oruc-keyboard-light.service
  '';

  systemd.user.services.oruc-keyboard-light = {
    Unit = {
      Description = "Set the keyboard or case lights to the stored scheme's base09";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe apply;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
