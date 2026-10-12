# Remote desktop hosting over Tailscale: Sunshine streams the niri session, and
# Moonlight on another machine connects.
{ config, lib, ... }:
lib.mkIf config.oruc.machine.features.remoteDesktop {
  services.sunshine = {
    enable = true;
    capSysAdmin = true; # KMS capture on Wayland
    autoStart = true;
    openFirewall = false; # tailscale0 is a trusted interface already
  };
  # Sunshine turns on Avahi so Moonlight finds the host on the LAN. Moonlight
  # reaches it over Tailscale by name, so mDNS stays closed on the LAN. This
  # host's own Moonlight and Remmina then find no LAN hosts either; add them
  # by name.
  services.avahi.openFirewall = false;
}
