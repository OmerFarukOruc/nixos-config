# Remote desktop hosting over Tailscale. Sunshine streams the login session, and
# Moonlight on another machine connects. Sunshine is a user service, so it
# starts only once someone logs in.
{ config, lib, ... }:
lib.mkIf config.oruc.machine.features.remoteDesktop {
  nixpkgs.overlays = [ (import ../overlays/sunshine.nix) ];
  services.sunshine = {
    enable = true;
    capSysAdmin = true; # KMS capture on Wayland
    autoStart = true;
    openFirewall = false; # tailscale0 is a trusted interface already
    # In automatic mode Sunshine on Plasma asked the XDG portal first, which
    # waits for someone to approve a dialog on the host's screen, so Sunshine
    # never started listening. KMS needs no approval. With settings set, the
    # web UI can no longer change the configuration, but pairing still works.
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
  # Sunshine turns on Avahi so Moonlight finds the host on the LAN. Moonlight
  # reaches it over Tailscale by name, so mDNS stays closed on the LAN. This
  # host's own Moonlight then finds no LAN hosts either; add them by name.
  services.avahi.openFirewall = false;
}
