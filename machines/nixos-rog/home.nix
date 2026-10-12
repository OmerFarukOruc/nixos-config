# Home Manager layer of nixos-rog: its own apps, htop meters and session
# variables, on top of the workstation profile.
{
  agents,
  osConfig,
  pkgs,
  ...
}:
{
  imports = [
    ../../home-manager/profiles/workstation.nix
    ./desktop-sync.nix
    ./easyeffects.nix
    ./hdr.nix
    ./mpv.nix
    ./warp-launchers.nix
  ];

  # Only these keys: input.touchpads would also delete every touchpad key it
  # does not set, such as pointer speed. The group name is this laptop's
  # vendor, product and device name.
  programs.plasma.configFile.kcminputrc."Libinput/10248/537/ASUF1209:00 2808:0219 Touchpad" = {
    Enabled = true;
    TapToClick = osConfig.oruc.machine.touchpad.tapToClick;
    NaturalScroll = osConfig.oruc.machine.touchpad.naturalScroll;
  };

  # Deskflow runs here as the client of fedora-desktop's server. A client on
  # Wayland types through the remote desktop portal, which Plasma has and niri
  # does not, so it starts at a Plasma login only.
  xdg.configFile."autostart/org.deskflow.deskflow.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Deskflow
    Exec=deskflow
    Icon=org.deskflow.deskflow
    OnlyShowIn=KDE;
  '';

  # The Ryzen AI 9 HX 370 has 24 threads.
  oruc.htop.cpuColumns = 4;

  home.sessionVariables = {
    # Playwright uses the nixpkgs browsers; npm's downloaded ones do not run here.
    PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
    PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
  };

  home.packages =
    with pkgs;
    [
      amdgpu_top
      android-tools
      antigravity-ide
      apkeep
      chromium
      code-cursor
      cudaPackages.cudatoolkit
      fastfetch
      frida-tools
      gum
      hwinfo
      iptvnator
      jadx
      kdePackages.kate
      lmstudio
      micro
      mitmproxy
      nvtopPackages.full
      obsidian
      pandoc
      podman-desktop
      qbittorrent
      silicon
      slack
      tigervnc
      vhs
      vlc
    ]
    ++ [
      (pkgs.callPackage ../../pkgs/chatgpt.nix { })
      (pkgs.callPackage ../../pkgs/openchamber.nix { })
    ]
    ++ (with agents; [
      agent-browser
      antigravity-cli
      pi
    ]);
}
