# Home Manager layer of nixos-rog: its own apps and session variables, on
# top of the workstation profile.
{
  agents,
  config,
  lib,
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
    ./hushmic.nix
    ./mpv.nix
    ./warp-launchers.nix
  ];

  # This sets only these keys, because input.touchpads would also delete every
  # touchpad key it does not set, such as pointer speed. The group name is this
  # laptop's vendor, product and device name.
  programs.plasma.configFile.kcminputrc."Libinput/10248/537/ASUF1209:00 2808:0219 Touchpad" = {
    Enabled = true;
    TapToClick = osConfig.oruc.machine.touchpad.tapToClick;
    NaturalScroll = osConfig.oruc.machine.touchpad.naturalScroll;
  };

  # Deskflow runs here as the client of fedora-desktop's server. A client on
  # Wayland types through the remote desktop portal, which Plasma has and niri
  # does not, so it starts at a Plasma login only. As a service, a switch that
  # changes Deskflow restarts it, so the running client is never the old build.
  systemd.user.services.deskflow = {
    Unit = {
      Description = "Deskflow client of fedora-desktop";
      # Only a Plasma session reaches plasma-workspace.target.
      After = [ "plasma-workspace.target" ];
      PartOf = [ "plasma-workspace.target" ];
    };
    Service = {
      ExecStart = lib.getExe pkgs.deskflow;
      Restart = "on-failure";
      RestartSec = 5;
      # Deskflow exits 5 when another instance runs, such as one started from
      # the menu. A restart would only raise that instance's window again.
      SuccessExitStatus = 5;
    };
    Install.WantedBy = [ "plasma-workspace.target" ];
  };

  # The client's log otherwise shows only in its window. Deskflow writes it to
  # ~/deskflow.log, as on fedora-desktop, and rotates it at 1 MiB. Deskflow
  # also saves its own settings in Deskflow.conf, so the switch sets only the
  # toFile key.
  home.activation.deskflowLogToFile =
    lib.hm.dag.entryBetween [ "reloadSystemd" ] [ "writeBoundary" ]
      ''
        run mkdir -p ${config.xdg.configHome}/Deskflow
        run ${lib.getExe pkgs.crudini} --ini-options=nospace --set \
          ${config.xdg.configHome}/Deskflow/Deskflow.conf log toFile true
      '';

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
      devenv
      fastfetch
      frida-tools
      gum
      hwinfo
      iptvnator
      jadx
      kdePackages.kate
      lmstudio
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
      (pkgs.callPackage ../../pkgs/grok-bot.nix { })
      (pkgs.callPackage ../../pkgs/openchamber.nix { })
    ]
    ++ (with agents; [
      agent-browser
      antigravity-cli
      pi
    ]);
}
