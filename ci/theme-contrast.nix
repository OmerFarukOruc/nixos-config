{ inputs, host }:
let
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  inherit (host) config;
  userPack = config.home-manager.users.${config.oruc.machine.user}.oruc.themePack;
in
{
  theme-contrast = pkgs.runCommand "theme-contrast" { } ''
    ${pkgs.python3.interpreter} -I ${../scripts/lib/theme-contrast.py} ${userPack} ${config.oruc.themeRoot.pack}
    touch "$out"
  '';
}
