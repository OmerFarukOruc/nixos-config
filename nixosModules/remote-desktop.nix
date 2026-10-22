# Remote desktop hosting over Tailscale. Sunshine streams the niri session, and
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
  # nixpkgs' sunshine module still sets the obsolete services.avahi.publish
  # options, which print two warnings. These lines set the same values the new
  # way. Remove them once the locked nixpkgs has
  # https://github.com/NixOS/nixpkgs/pull/577274; evaluation fails here when
  # nixpkgs drops the old options.
  services.avahi.publish = {
    enable = lib.mkForce null;
    userServices = lib.mkForce null;
  };
  services.avahi.settings.publish = {
    disable-publishing = false;
    disable-user-service-publishing = false;
    publish-addresses = true;
  };
}
