{
  setColour,
  waitFor ? null,
}:
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
      ${lib.optionalString (waitFor != null) ''
        for _ in $(seq 30); do
          systemctl is-active -q ${waitFor} && break
          sleep 1
        done
      ''}
      colour=$(cat ${config.oruc.themeFactsDir}/keyboard-light)
      timeout 20 ${setColour "\"$colour\""}
    '';
  };
in
{
  oruc.themeFacts.keyboard-light = { scheme, ... }: scheme.base09;

  oruc.variantReloads.keyboard-light = lib.getExe apply;

  systemd.user.services.oruc-keyboard-light = {
    Unit = {
      Description = "Set the keyboard or case lights to the stored scheme's base09";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = lib.getExe apply;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
