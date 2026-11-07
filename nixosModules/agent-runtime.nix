{ pkgs, ... }:
{
  services.xserver.desktopManager.xfce = {
    enable = true;
    enableScreensaver = false;
  };
  programs.labwc.enable = true;

  environment.systemPackages = with pkgs; [
    chromium
    cmake
    ffmpeg
    imagemagick
    parallel
    (callPackage ../pkgs/agent-python.nix { })
    sqlite
    tigervnc
    # The Cursor worker looks for Debian's name of the TigerVNC X server and
    # refuses computer use without it; nixpkgs names it Xvnc.
    (runCommand "xtigervnc" { } ''
      mkdir -p $out/bin
      ln -s ${tigervnc}/bin/Xvnc $out/bin/Xtigervnc
    '')
    tree
    unzip
    wlr-randr
    xauth
    xdotool
    xdpyinfo
    xprop
    xrandr
    xrdb
    xset
    xsetroot
    xvfb
    xwininfo
  ];

  fonts.packages = with pkgs; [
    freefont_ttf
    ipafont
    liberation_ttf
    noto-fonts-color-emoji
    tlwg
    unifont
    wqy_zenhei
  ];

  environment.enableAllTerminfo = true;
}
