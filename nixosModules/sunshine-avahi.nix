# For any host that runs Sunshine, which the workstations do through
# remote-desktop.nix.
{ config, lib, ... }:
lib.mkIf config.services.sunshine.enable {
  # nixpkgs' sunshine module still sets the obsolete services.avahi.publish
  # options (as defaults), which print two warnings. These lines set them to
  # null, which silences the warnings, and set the same values the new way.
  # Remove them once the locked nixpkgs has
  # https://github.com/NixOS/nixpkgs/pull/577274; evaluation fails here when
  # nixpkgs drops the old options.
  services.avahi.publish = {
    enable = null;
    userServices = null;
  };
  services.avahi.settings.publish = {
    disable-publishing = false;
    disable-user-service-publishing = false;
    publish-addresses = true;
  };
}
