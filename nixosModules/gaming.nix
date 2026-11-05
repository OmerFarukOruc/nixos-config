{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf config.oruc.machine.features.gaming {
  nixpkgs.overlays = [ (import ../overlays/proton-ge-bin.nix) ];

  programs.steam = {
    enable = true;
    protontricks.enable = true;
    extraCompatPackages = [
      pkgs.proton-ge-bin
      (pkgs.callPackage ../pkgs/proton-cachyos.nix { })
      (pkgs.callPackage ../pkgs/proton-wineland.nix { })
    ];
  };

  # Proton and Wine use ntsync when /dev/ntsync exists; the kernel creates it
  # world-writable, so it needs no udev rule.
  boot.kernelModules = [ "ntsync" ];

  # wineserver maps a game thread's Windows priority into the nice range that
  # RLIMIT_NICE allows (server/thread.c), so this lets it raise game threads.
  security.pam.loginLimits = [
    {
      domain = config.oruc.machine.user;
      type = "-";
      item = "nice";
      value = "-8";
    }
  ];

  environment.systemPackages = [
    pkgs.mangohud
    pkgs.vulkan-tools
  ];
}
