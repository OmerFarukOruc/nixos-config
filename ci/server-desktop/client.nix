# The node that connects to the desktop: Alice's X session, with an RDP client,
# Moonlight and an audio server, and a second network card for the tailnet
# side.
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
  # An audio server like the workstations have (nixosModules/multimedia.nix),
  # so Moonlight opens a sink as it does on a real client. The VM has no
  # sound card, and PipeWire's default config makes a dummy sink for that.
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
    wireplumber.enable = true;
  };
  environment.systemPackages = with pkgs; [
    freerdp
    imagemagick
    netcat-openbsd
    pulseaudio # pactl
    xdotool
  ];
}
