{
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  cfg = osConfig.oruc.machine;
  selected = sessions.hasAnyDesktop cfg && cfg.launcher == "fuzzel";
  helpers = import ./helpers.nix { inherit lib pkgs; };
  # Hex without "#", which fuzzel expects before the alpha byte.
  inherit (osConfig) scheme;
  inherit (osConfig.oruc.theme) fonts;
  commands = {
    app = "exec ${lib.getExe pkgs.fuzzel}";
    command = ''
      choice="$(compgen -c | ${pkgs.coreutils}/bin/sort -u | ${lib.getExe pkgs.fuzzel} --dmenu --prompt='Run: ')"
      [[ -z "$choice" ]] || exec ${pkgs.bash}/bin/bash -lc "$choice"
    '';
    ssh = helpers.sshVia "${lib.getExe pkgs.fuzzel} --dmenu --prompt='SSH: '";
    file = helpers.fileVia "${lib.getExe pkgs.fuzzel} --dmenu --prompt='File: '";
  };
in
{
  config = lib.mkIf selected {
    home.packages = helpers.packagesFor commands;

    programs.fuzzel = {
      enable = true;
      settings = {
        main = {
          font = "${fonts.ui}:size=11";
          inherit (helpers) terminal;
          width = 42;
        };
        colors = {
          background = "${scheme.base00}f2";
          text = "${scheme.base05}ff";
          match = "${scheme.base0D}ff";
          selection = "${scheme.base02}ff";
          selection-text = "${scheme.base07}ff";
          border = "${scheme.base0D}ff";
        };
        border = {
          width = 2;
          radius = 10;
        };
      };
    };
  };
}
