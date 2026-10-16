{
  config,
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  cfg = osConfig.oruc.machine;
  selected = sessions.hasAnyDesktop cfg && cfg.launcher == "anyrun";
  helpers = import ./helpers.nix { inherit lib pkgs; };
  scheme = config.scheme.withHashtag;
  anyrunLib = "${pkgs.anyrun}/lib";
  stdinPicker = "${lib.getExe pkgs.anyrun} --plugins ${anyrunLib}/libstdin.so";
  commands = {
    app = "exec ${lib.getExe pkgs.anyrun} --plugins ${anyrunLib}/libapplications.so";
    command = "exec ${lib.getExe pkgs.anyrun} --plugins ${anyrunLib}/libshell.so";
    ssh = helpers.sshVia stdinPicker;
    file = helpers.fileVia stdinPicker;
  };
in
{
  config = lib.mkIf selected {
    home.packages = helpers.packagesFor commands;

    programs.anyrun = {
      enable = true;
      config = {
        plugins = [ "${anyrunLib}/libapplications.so" ];
        width.fraction = 0.45;
        hideIcons = false;
        layer = "overlay";
      };
      extraCss = ''
        window { background: transparent; }
        #match { color: ${scheme.base05}; background: ${scheme.base01}; }
        #match:selected { background: ${scheme.base02}; border-left: 3px solid ${scheme.base0D}; }
        #entry { color: ${scheme.base05}; background: ${scheme.base00}; border: 2px solid ${scheme.base0D}; }
      '';
    };
  };
}
