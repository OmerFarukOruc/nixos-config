{ pkgs, ... }:
{
  test-support.displayManager.auto.user = "alice";
  virtualisation = {
    memorySize = 4096;
    cores = 4;
    vlans = [
      1
      2
    ];
    resolution = {
      x = 1920;
      y = 1080;
    };
  };
  services.xserver.xkb.layout = "tr";
  environment.systemPackages = with pkgs; [
    freerdp
    imagemagick
    netcat-openbsd
    xdotool
  ];
}
