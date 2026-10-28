# What the coding agents of a server run against: the /usr/bin paths that
# scripts and user units hardcode, and the tools the Cursor worker and the Amp runner drive
# on their virtual desktops.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  # Units from the dotfiles checkout start /usr/bin/zsh, /usr/bin/bash,
  # /usr/bin/systemctl and /usr/bin/podman, and envfs looks a name up in the
  # PATH of the caller. This fallback finds these names when that PATH does not
  # hold them. podman is the link of the system profile, because the NixOS
  # module wraps it with the setuid newuidmap and newgidmap that rootless
  # Podman needs, and referencing the module's package here recurses.
  # rootless-containers.nix turns that module on.
  services.envfs.extraFallbackPathCommands = ''
    ln -s ${lib.getExe pkgs.bash} $out/bash
    ln -s ${lib.getExe pkgs.zsh} $out/zsh
    ln -s ${config.systemd.package}/bin/systemctl $out/systemctl
    ln -s /run/current-system/sw/bin/podman $out/podman
  '';

  # The Cursor worker (computer use) drives an X session on Xvnc with XFCE, and
  # the Amp runner (desktop) drives a labwc Wayland session. Neither starts a
  # login manager. The XFCE module also turns on udisks2, accounts-daemon, gvfs,
  # tumbler, colord, polkit and gnome-keyring. Its screensaver would lock the
  # Cursor worker's session, where nobody types a password; the Debian box had
  # no screensaver installed (dpkg-query, 2026-10-28).
  services.xserver.desktopManager.xfce = {
    enable = true;
    enableScreensaver = false;
  };
  programs.labwc.enable = true;

  environment.systemPackages = with pkgs; [
    chromium
    cmake
    ffmpeg
    gettext # envsubst, which cliproxy-up.sh calls
    imagemagick
    parallel
    python3
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

  # Chromium draws no text without a font; these cover the system Chromium and
  # the desktops' applications.
  fonts.packages = with pkgs; [
    freefont_ttf
    ipafont
    liberation_ttf
    noto-fonts-color-emoji
    tlwg
    unifont
    wqy_zenhei
  ];

  # Every terminal type, because agents log in from many terminals.
  environment.enableAllTerminfo = true;
}
