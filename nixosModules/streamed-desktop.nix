{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf config.oruc.machine.features.streamedDesktop {
  nixpkgs.overlays = [ (import ../overlays/xrdp.nix) ];

  services.xserver.desktopManager.xfce = {
    enable = true;
    enableScreensaver = false;
  };

  services.xrdp = {
    enable = true;
    defaultWindowManager = "${pkgs.dbus}/bin/dbus-run-session xfce4-session";
    openFirewall = false;
    extraConfDirCommands = ''
      substituteInPlace $out/xrdp.ini --replace-fail EnableSyslog=false EnableSyslog=true
      substituteInPlace $out/sesman.ini \
        --replace-fail EnableSyslog=false EnableSyslog=true \
        --replace-fail AllowRootLogin=true AllowRootLogin=false
    '';
  };
}
