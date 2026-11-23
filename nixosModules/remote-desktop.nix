{ config, lib, ... }:
lib.mkIf config.oruc.machine.features.remoteDesktop {
  nixpkgs.overlays = [ (import ../overlays/sunshine.nix) ];
  services.sunshine = {
    enable = true;
    capSysAdmin = true; # KMS capture on Wayland
    autoStart = false;
    openFirewall = false;
    # In automatic mode Sunshine on Plasma asked the XDG portal first, which
    # waits for someone to approve a dialog on the host's screen, so Sunshine
    # never started listening. KMS needs no approval. With settings set, the
    # web UI can no longer change the configuration, but pairing still works.
    settings.capture = "kms";
    applications.apps = [
      {
        name = "Desktop";
        image-path = "desktop.png";
      }
    ]
    ++ lib.optional config.programs.steam.enable {
      name = "Steam Big Picture";
      image-path = "steam.png";
      detached = [ "setsid steam steam://open/bigpicture" ];
      prep-cmd = [
        {
          do = "";
          undo = "setsid steam steam://close/bigpicture";
        }
      ];
    };
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
  # The package's entry runs a bare `sunshine`, which reads ~/.config/sunshine
  # instead of the generated sunshine.conf that only the unit passes. The same
  # desktop-file ID in the user profile shadows it.
  home-manager.users.${config.oruc.machine.user}.xdg.desktopEntries."dev.lizardbyte.app.Sunshine" = {
    name = "Sunshine";
    comment = "Self-hosted game stream host for Moonlight";
    exec = "systemctl --user start sunshine.service";
    icon = "dev.lizardbyte.app.Sunshine";
    categories = [
      "RemoteAccess"
      "Network"
    ];
  };
}
