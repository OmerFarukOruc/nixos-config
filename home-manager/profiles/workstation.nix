{ lib, pkgs, ... }:
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
