# OpenRGB sets the case lights from openrgb-boot.json at boot, then exits; no
# OpenRGB server runs, so the profile holds one steady colour. OpenRGB matches
# each device by name, version and serial, not by its /dev/hidraw path, so the
# profile keeps the two controllers' serials. The window works as oruc through
# the package's udev rules.
#
# The Razer controller drives every light; the motherboard's headers are empty.
# Its channels hold 15 LEDs per Phanteks D30 fan and 12 for the Arctic pump:
# 1 the bottom fans, 2 the side fans, 3 the top fans, 4 the rear fan, 5 nothing,
# 6 the pump head. OpenRGB takes these zone sizes only from Configuration.json;
# `--profile` skips the sizes in a profile and then drops its colours as well,
# because their count no longer matches. The profile therefore doubles as
# Configuration.json, for the boot service and for the window.
{ pkgs, ... }:
let
  install = "${pkgs.coreutils}/bin/install -D -m 0644 ${./openrgb-boot.json}";
in
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
    # OpenRGB reads its configuration from $HOME/.config/OpenRGB.
    environment.HOME = "/var/lib/openrgb-boot";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "openrgb-boot";
      ExecStartPre = [
        # The USB controllers show up a moment after the modules load.
        "${pkgs.coreutils}/bin/sleep 3"
        "${install} /var/lib/openrgb-boot/.config/OpenRGB/profiles/boot.json"
        "${install} /var/lib/openrgb-boot/.config/OpenRGB/Configuration.json"
      ];
      ExecStart = "${pkgs.openrgb}/bin/openrgb --profile boot";
    };
  };

  # The window writes both files, so they are copies, not store links. Each
  # switch puts back the repository's zone sizes and boot profile.
  home-manager.users.oruc =
    { config, lib, ... }:
    {
      home.activation.openrgbProfile = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${install} ${config.xdg.configHome}/OpenRGB/profiles/boot.json
        run ${install} ${config.xdg.configHome}/OpenRGB/Configuration.json
      '';
    };
}
