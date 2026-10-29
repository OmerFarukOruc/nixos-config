{
  inputs,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    inputs.sops-nix.nixosModules.sops
    ./apps.nix
    ./asus.nix
    ./auto-update.nix
    ./claude-tools-usage-read.nix
    ./cpu-limits.nix
    ../../nixosModules/envfs.nix
    ./graphics.nix
    ./low-battery.nix
    ./media.nix
    ./monitoring.nix
    ./network.nix
    ../../nixosModules/nextdns.nix
    ../../nixosModules/nixpkgs-clone.nix
    ./powertop.nix
    ./profile-sync.nix
    ./stay-active.nix
    ../../nixosModules/warp.nix
    ./zapret2.nix
  ];

  boot.loader.limine.style.interface.branding = "NixOS on ROG";
  boot.loader.limine.extraEntries = ''
    /Windows
        protocol: efi
        path: boot():/EFI/Microsoft/Boot/bootmgfw.efi
  '';

  # The recovery boot entry runs the newest mainline kernel. asus-armoury, which
  # sets the GPU mode and power limits, is in mainline from 6.19, so the stock
  # 6.18 kernel cannot drive this laptop. The normal entry runs the CachyOS
  # kernel of kernel.profile in machines/inventory.nix.
  oruc.recovery.kernelPackages = pkgs.linuxPackages_latest;

  boot.kernelParams = [ "cfg80211.ieee80211_regdom=TR" ];

  programs.appimage = {
    enable = true;
    binfmt = true;
  };

  fileSystems."/mnt/windows" = {
    device = "/dev/disk/by-uuid/3818FB0C18FAC7C0";
    fsType = "ntfs3";
    noCheck = true;
    options = [
      "ro"
      "nofail"
      "noauto"
      "x-systemd.automount"
      "x-systemd.idle-timeout=10min"
    ];
  };

  nix.daemonCPUSchedPolicy = "batch";

  services.scx = {
    enable = true;
    scheduler = "scx_lavd";
    extraArgs = [ "--performance" ];
  };
  # The scheduler's daemon must run when the CPUs are saturated, and comes
  # back after a crash. A crash loop still hits the unit's start limit of 2
  # starts in 30 s and leaves it failed. RT throttling is off on this kernel,
  # so a spinning daemon would hold a CPU.
  systemd.services.scx.serviceConfig = {
    CPUSchedulingPolicy = "fifo";
    CPUSchedulingPriority = 99;
    IOSchedulingClass = "realtime";
    Restart = lib.mkForce "always";
    RestartSec = 3;
  };

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 100;
  };
  boot.kernel.sysctl = {
    "vm.watermark_boost_factor" = 0;
    "vm.watermark_scale_factor" = 125;
    "vm.dirty_bytes" = 268435456;
    "vm.dirty_background_bytes" = 67108864;
    "kernel.nmi_watchdog" = 0;
  };

  sops = {
    defaultSopsFile = ../../secrets/nixos-rog.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };

  home-manager.users.oruc.imports = [
    ./home.nix
    ../../home-manager/profiles/personal.nix
  ];

  system.stateVersion = "26.11";
}
