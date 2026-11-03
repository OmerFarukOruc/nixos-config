{
  setColour,
  lightService,
  ready ? "systemctl is-active -q ${lightService}",
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  facts = lib.escapeShellArg "${config.oruc.themeFactsDir}/keyboard-light";
  applied = "oruc-keyboard-light";
  owner = "systemctl show -P InvocationID ${lightService}";
  apply = pkgs.writeShellApplication {
    name = "oruc-keyboard-light";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      rm -f "$XDG_RUNTIME_DIR/${applied}"
      for _ in $(seq 30); do
        ${ready} && break
        sleep 1
      done
      colour=$(<${facts})
      timeout 20 ${setColour "\"$colour\""}
      echo "$(${owner}) $colour" >"$XDG_RUNTIME_DIR/${applied}"
    '';
  };
in
{
  oruc.themeFacts.keyboard-light = { scheme, ... }: scheme.base09;

  oruc.variantReloads.keyboard-light = ''
    systemctl --user is-active -q graphical-session.target || exit 0
    applied=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${applied}
    if [[ -r $applied && $(<"$applied") == "$(${owner}) $(<${facts})" ]]; then
      exit 0
    fi
    systemctl --user restart oruc-keyboard-light.service
  '';

  systemd.user.services.oruc-keyboard-light = {
    Unit = {
      Description = "Set the keyboard or case lights to the stored scheme's base09";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      X-SwitchMethod = "keep-old";
    };
    Service = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe apply;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
