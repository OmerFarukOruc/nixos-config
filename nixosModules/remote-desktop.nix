{ config, lib, ... }:
lib.mkIf config.oruc.machine.features.remoteDesktop {
  nixpkgs.overlays = [ (import ../overlays/sunshine.nix) ];
  services.sunshine = {
    enable = true;
    capSysAdmin = true;
    autoStart = true;
    openFirewall = false;
    settings.capture = "kms";
  };
  # A restart from the tray menu or web UI exits with 75 (overlays/sunshine.nix).
  # systemd starts Sunshine again through the capability wrapper, and the unit
  # does not count as failed. Each such restart is a start, and nixpkgs allows
  # 5 starts in 500 s. Past the limit Sunshine stays stopped, and only
  # `systemctl --user reset-failed sunshine` before a start brings it back. 20
  # leaves room for repeated restarts while a fast crash loop, 5 s apart, still
  # stops after about 100 s.
  systemd.user.services.sunshine = {
    startLimitBurst = lib.mkForce 20;
    serviceConfig = {
      RestartForceExitStatus = 75;
      SuccessExitStatus = 75;
    };
  };
  services.avahi.openFirewall = false;
}
