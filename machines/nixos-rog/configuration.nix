{
  inputs,
  pkgs,
  ...
}:

{
  imports = [
    inputs.sops-nix.nixosModules.sops
    ./apps.nix
    ./asus.nix
    ./claude-tools-usage-read.nix
    ./cpu-limits.nix
    ../../nixosModules/agents.nix
    ../../nixosModules/install-reports.nix
    ../../nixosModules/envfs.nix
    ./gaming.nix
    ./graphics.nix
    ./low-battery.nix
    ./media.nix
    ./network.nix
    ../../nixosModules/nextdns.nix
    ../../nixosModules/ssh-hosts.nix
    ../../nixosModules/nixpkgs-clone.nix
    ./powertop.nix
    ./profile-sync.nix
    ../../nixosModules/via-devbox.nix
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

  security.tpm2.enable = true;
  users.users.oruc.extraGroups = [ "tss" ];

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

  oruc.autoUpgrade.enable = true;

  home-manager.users.oruc.imports = [
    ./home.nix
    ../../home-manager/profiles/personal.nix
  ];

  system.stateVersion = "26.11";
}
