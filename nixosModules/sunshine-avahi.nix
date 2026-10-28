{ config, lib, ... }:
lib.mkIf config.services.sunshine.enable {
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
