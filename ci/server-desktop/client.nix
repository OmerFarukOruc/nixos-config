# The node that connects to the desktop: Alice's X session, with an RDP client
# and Moonlight, and a second network card for the tailnet side.
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
  programs.moonlight-qt.enable = true;
  environment.systemPackages = with pkgs; [
    freerdp
    imagemagick
    netcat-openbsd
    xdotool
  ];
}
