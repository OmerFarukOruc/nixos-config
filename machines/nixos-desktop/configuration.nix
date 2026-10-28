{ inputs, ... }:

{
  imports = [
    inputs.sops-nix.nixosModules.sops
    ../../nixosModules/envfs.nix
    ../../nixosModules/nextdns.nix
    ../../nixosModules/nixpkgs-clone.nix
    ../../nixosModules/warp.nix
    ../../nixosModules/zapret2.nix
    ./fans.nix
    ./gpu.nix
    ./openrgb.nix
  ];

  boot.loader.limine.style.interface.branding = "NixOS on desktop";
  services.zapret2.firewall.interfaces = [ "enp14s0" ];
  # Windows Boot Manager is on the Samsung disk's ESP, named by its partition
  # GUID because Limine's boot() means the ESP it booted from.
  boot.loader.limine.extraEntries = ''
    /Windows
        protocol: efi
        path: guid(10036113-64c6-4117-9dd5-ea8b222762ea):/EFI/Microsoft/Boot/bootmgfw.efi
  '';

  boot.kernelModules = [ "sp5100_tco" ];

  # Windows keeps the hardware clock in local time.
  time.hardwareClockInLocalTime = true;

  programs.appimage = {
    enable = true;
    binfmt = true;
  };

  nix.daemonCPUSchedPolicy = "batch";

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 100;
  };

  users.users.oruc.linger = true;

  security.tpm2.enable = true;
  users.users.oruc.extraGroups = [ "tss" ];

  # browser-lend runs `tailscale serve` as oruc, which needs the operator. The
  # list adds to the shared flags in nixosModules/connectivity.nix.
  services.tailscale.extraSetFlags = [ "--operator=oruc" ];

  systemd.services.sshd.serviceConfig.OOMScoreAdjust = -900;
  systemd.services.tailscaled.serviceConfig.OOMScoreAdjust = -900;

  sops = {
    defaultSopsFile = ../../secrets/nixos-desktop.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  };

  home-manager.users.oruc.imports = [
    ./home.nix
    ../../home-manager/profiles/personal.nix
  ];

  system.stateVersion = "26.11";
}
