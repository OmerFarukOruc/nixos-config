# ASUS ROG Zephyrus G16 GA605WI. Written by hand from the CachyOS install it
# replaced on the same btrfs file system. The NixOS subvolumes sit at the top
# level of that file system.
{ lib, modulesPath, ... }:
let
  btrfs = "/dev/disk/by-uuid/6a77e7a8-4ab9-42be-985f-eeecb7ade813";
  subvolume = name: {
    device = btrfs;
    fsType = "btrfs";
    options = [
      "subvol=${name}"
      "compress=zstd:1"
      "noatime"
    ];
  };
in
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "thunderbolt"
    "usbhid"
    "usb_storage"
    "sd_mod"
    "sdhci_pci"
  ];
  boot.kernelModules = [ "kvm-amd" ];

  fileSystems."/" = subvolume "@nixos";
  fileSystems."/home" = subvolume "@nixos-home";
  fileSystems."/nix" = subvolume "@nixos-nix";
  fileSystems."/var/log" = subvolume "@nixos-log" // {
    neededForBoot = true;
  };

  # Shared with Windows Boot Manager.
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/0D35-447F";
    fsType = "vfat";
    options = [
      "fmask=0077"
      "dmask=0077"
    ];
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = true;
}
