# Home desktop: MSI MAG B650 Tomahawk WiFi, Ryzen 7 7800X3D, Radeon RX 7900
# XTX. NixOS is on the WD SN850X; Windows keeps the Samsung 990 PRO and its
# own ESP. Role and login sessions: machines/inventory.nix.
{ inputs, ... }:

{
  imports = [
    inputs.sops-nix.nixosModules.sops
    ../../nixosModules/nextdns.nix
    ../../nixosModules/warp.nix
    ../../nixosModules/zapret2.nix
    ./fans.nix
    ./gpu.nix
    ./openrgb.nix
  ];

  boot.loader.limine.style.interface.branding = "NixOS on desktop";
  # The wired port with the default route; wlp15s0 is down and left out.
  services.zapret2.firewall.interfaces = [ "enp14s0" ];
  # Windows Boot Manager is on the Samsung disk's ESP, named by its partition
  # GUID because Limine's boot() means the ESP it booted from.
  boot.loader.limine.extraEntries = ''
    /Windows
        protocol: efi
        path: guid(10036113-64c6-4117-9dd5-ea8b222762ea):/EFI/Microsoft/Boot/bootmgfw.efi
  '';

  # The hardware watchdog for features.alwaysOn. The driver loads only on
  # request, because many distributions blacklist it.
  boot.kernelModules = [ "sp5100_tco" ];

  # Windows keeps the hardware clock in local time.
  time.hardwareClockInLocalTime = true;

  # Scripts from other repositories run with their `#!/bin/bash` shebangs.
  # envfs serves /bin and /usr/bin from the PATH of the calling process.
  services.envfs.enable = true;

  nix.daemonCPUSchedPolicy = "batch";

  # Compressed swap in RAM, sized to all of it. No disk swap.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 100;
  };

  # oruc's user services, such as the sshfs mount, keep running without a
  # login session.
  users.users.oruc.linger = true;

  # The AWS Roles Anywhere key is sealed in the TPM; tss may use the TPM.
  security.tpm2.enable = true;
  users.users.oruc.extraGroups = [ "tss" ];

  # browser-lend runs `tailscale serve` as oruc, which needs the operator. The
  # list adds to the shared flags in nixosModules/connectivity.nix.
  services.tailscale.extraSetFlags = [ "--operator=oruc" ];

  # The kernel kills other processes before the ways in.
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
