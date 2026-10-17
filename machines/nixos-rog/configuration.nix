# ASUS ROG Zephyrus G16 GA605WI (Ryzen AI 9 HX 370, Radeon 890M, RTX 4070
# Laptop). Daily laptop, installed beside Windows on a shared ESP.
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
    ./cpu-limits.nix
    ./graphics.nix
    ./low-battery.nix
    ./media.nix
    ./monitoring.nix
    ./network.nix
    ./nixpkgs-clone.nix
    ./powertop.nix
    ./root-reset.nix
    ./stay-active.nix
    ./warp.nix
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

  # Turkey's Wi-Fi rules instead of the world domain, which limits channels
  # and power.
  boot.kernelParams = [ "cfg80211.ieee80211_regdom=TR" ];

  # Runs AppImages directly, through binfmt.
  programs.appimage = {
    enable = true;
    binfmt = true;
  };

  # The Windows system partition, read-only, mounted on first access.
  fileSystems."/mnt/windows" = {
    device = "/dev/disk/by-uuid/3818FB0C18FAC7C0";
    fsType = "ntfs3";
    # There is no NTFS fsck here, and a failed check would stop the mount.
    noCheck = true;
    options = [
      "ro"
      "nofail"
      "noauto"
      "x-systemd.automount"
      "x-systemd.idle-timeout=10min"
    ];
  };

  # Builds run as batch work, so the scheduler favours the desktop over them.
  # latitude, the lab box, uses idle instead.
  nix.daemonCPUSchedPolicy = "batch";

  # Kernel scheduler from sched_ext. --autopower follows power-profiles-daemon.
  services.scx = {
    enable = true;
    scheduler = "scx_lavd";
    extraArgs = [ "--autopower" ];
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

  # Compressed swap in RAM, sized to all of it. No disk swap, so no hibernate.
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

  home-manager.users.oruc.imports = [ ./home.nix ];

  system.stateVersion = "26.11";
}
