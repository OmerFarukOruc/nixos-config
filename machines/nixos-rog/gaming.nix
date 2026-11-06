{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf config.programs.steam.enable {
  programs.steam.package = pkgs.steam.override {
    extraEnv = {
      VK_LOADER_DRIVERS_SELECT = "*radeon*";
      MANGOHUD = "1";
    };
  };
}
