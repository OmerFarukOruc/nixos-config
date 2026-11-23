{ pkgs, ... }:
{
  services.xserver.desktopManager.xfce = {
    enable = true;
    enableScreensaver = false;
  };
  systemd.user.services.xfce4-notifyd.enable = false;
  programs.labwc.enable = true;
  # The Amp runner's desktop sharing downloads waymote-streamd, a prebuilt
  # binary that loads these through nix-ld.
  programs.nix-ld.libraries = with pkgs; [
    libxkbcommon
    wayland
  ];

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
    # refuses computer use without it, and starts it with no -auth, so the
    # wrapper adds the X cookie; nixpkgs names it Xvnc.
    (writeShellApplication {
      name = "Xtigervnc";
      runtimeInputs = [
        coreutils
        util-linux
        xauth
      ];
      text = ''
        cookie_file="$HOME/.local/state/xtigervnc-cookie"
        if [[ ! -s $cookie_file ]]; then
          mkdir -p "$(dirname "$cookie_file")"
          (umask 077 && mcookie >"$cookie_file")
        fi
        cookie=$(<"$cookie_file")
        for number in {0..9}; do
          printf 'add :%s . %s\n' "$number" "$cookie"
        done | xauth -f "$HOME/.Xauthority" source -
        exec ${tigervnc}/bin/Xvnc -auth "$HOME/.Xauthority" "$@"
      '';
    })
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
