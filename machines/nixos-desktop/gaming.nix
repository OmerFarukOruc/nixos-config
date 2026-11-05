{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf config.programs.steam.enable {
  programs.steam.package = pkgs.steam.override {
    extraEnv = {
      PROTON_FSR4_UPGRADE = "1";
      MANGOHUD = "1";
    };
  };

  # capSysNice would install gamescope only as a capability wrapper, which
  # fails inside Steam's bubblewrap: https://github.com/NixOS/nixpkgs/issues/351516
  programs.gamescope.enable = true;
}
