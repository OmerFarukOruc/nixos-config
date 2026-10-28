{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ../modules/airpods.nix
    ../modules/spicetify.nix
  ];

  xdg.mimeApps.defaultApplications = {
    "inode/directory" = [ "org.kde.dolphin.desktop" ];
  }
  // lib.genAttrs [
    "application/gzip"
    "application/vnd.rar"
    "application/x-7z-compressed"
    "application/x-bzip2"
    "application/x-bzip2-compressed-tar"
    "application/x-compressed-tar"
    "application/x-rar"
    "application/x-tar"
    "application/x-xz"
    "application/x-xz-compressed-tar"
    "application/x-zstd-compressed-tar"
    "application/zip"
    "application/zstd"
  ] (_: [ "org.kde.ark.desktop" ]);

  # Mission Center opens its "Enabling Additional Values" setup dialog on the
  # first launch without checking anything. nixosModules/mission-center.nix
  # already grants what its setup script would, and the script cannot write
  # NixOS's udev rules, so the dialog never opens.
  dconf.settings."io/missioncenter/MissionCenter".first-time-running = false;

  # The RDP client for the desktop of risoluto-dev-1
  # (nixosModules/streamed-desktop.nix). It starts when Omer opens it, not in
  # the tray at login.
  services.remmina = {
    enable = true;
    systemdService.enable = false;
  };
  # xrdp gives the session the keyboard layout that the client sends, and
  # Remmina sends the one of this preference. At its default (0) FreeRDP
  # guesses: from the layout names on the X root window, which a Wayland
  # session may not set, and then from the locale, en_US here
  # (nixosModules/common.nix), so the session may get us instead of the
  # Turkish Q layout (0x041F) of these machines.
  home.activation.remminaKeyboardLayout = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run mkdir -p "${config.xdg.configHome}/remmina"
    run ${lib.getExe pkgs.crudini} --ini-options=nospace --set \
      "${config.xdg.configHome}/remmina/remmina.pref" \
      remmina_pref rdp_keyboard_layout 41F
  '';

  home.packages =
    with pkgs;
    [
      # keep-sorted start
      deskflow
      # The dev shell and git hooks of a nixos-config checkout (devenv.nix).
      devenv
      discord
      kdePackages.ark
      kdePackages.dolphin
      kdePackages.kio-extras
      mission-center
      moonlight-qt
      telegram-desktop
      wl-clipboard
      # keep-sorted end
    ]
    ++ [ (pkgs.callPackage ../../pkgs/claude-desktop.nix { }) ];
}
