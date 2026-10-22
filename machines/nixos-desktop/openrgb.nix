# OpenRGB sets the motherboard's and the Razer controller's lights from
# openrgb-boot.json at boot, then exits; no OpenRGB server runs. The profile
# was saved from the OpenRGB window on Fedora. OpenRGB matches each device by
# name, version and serial, not by its /dev/hidraw path. The window works as
# oruc through the package's udev rules.
{ pkgs, ... }:
{
  boot.kernelModules = [
    "i2c-dev"
    "i2c-piix4"
  ];
  services.udev.packages = [ pkgs.openrgb ];
  environment.systemPackages = [ pkgs.openrgb ];

  systemd.services.openrgb-boot = {
    description = "Apply the OpenRGB boot profile";
    after = [ "systemd-modules-load.service" ];
    wants = [ "systemd-modules-load.service" ];
    wantedBy = [ "multi-user.target" ];
    # OpenRGB reads its profiles from $HOME/.config/OpenRGB.
    environment.HOME = "/var/lib/openrgb-boot";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "openrgb-boot";
      ExecStartPre = [
        # The USB controllers show up a moment after the modules load.
        "${pkgs.coreutils}/bin/sleep 3"
        "${pkgs.coreutils}/bin/install -D -m 0644 ${./openrgb-boot.json} /var/lib/openrgb-boot/.config/OpenRGB/profiles/boot.json"
      ];
      ExecStart = "${pkgs.openrgb}/bin/openrgb --profile boot";
    };
  };
}
