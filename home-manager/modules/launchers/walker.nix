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
  selected = sessions.hasAnyDesktop cfg && cfg.launcher == "walker";
  helpers = import ./helpers.nix { inherit lib pkgs; };
  scheme = config.scheme.withHashtag;
  inherit (config.oruc.theme) fonts;
  commands = {
    app = "exec ${lib.getExe pkgs.walker} --provider desktopapplications";
    command = "exec ${lib.getExe pkgs.walker} --provider runner";
    ssh = helpers.sshVia "${lib.getExe pkgs.walker} --dmenu";
    file = "exec ${lib.getExe pkgs.walker} --provider files";
  };
in
{
  config = lib.mkIf selected {
    home.packages = helpers.packagesFor commands;

    services.elephant = {
      enable = true;
      settings.providers.default = [
        "desktopapplications"
        "files"
        "runner"
      ];
    };

    services.walker = {
      enable = true;
      systemd.enable = true;
      enableElephantIntegration = true;
      theme = {
        name = "oruc-base16";
        style = ''
          * { color: ${scheme.base05}; font-family: "${fonts.ui}"; }
          #window { background: ${scheme.base00}; border: 2px solid ${scheme.base0D}; border-radius: 10px; }
          #entry:selected { background: ${scheme.base02}; }
        '';
      };
    };
  };
}
