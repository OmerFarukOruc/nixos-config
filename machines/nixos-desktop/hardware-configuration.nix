# MSI MAG B650 Tomahawk WiFi with NixOS on the WD SN850X. Written by hand;
# docs/install-nixos-desktop.md creates the two GPT partitions with these
# names, so no file system UUID is needed here.
{ lib, modulesPath, ... }:
let
  btrfs = "/dev/disk/by-partlabel/nixos";
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
    "ahci"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  boot.kernelModules = [ "kvm-amd" ];

  fileSystems."/" = subvolume "@nixos";
  fileSystems."/home" = subvolume "@nixos-home";
  fileSystems."/nix" = subvolume "@nixos-nix";
  fileSystems."/var/log" = subvolume "@nixos-log" // {
    neededForBoot = true;
  };

  # This disk's own ESP. Windows keeps the one on the Samsung disk.
  fileSystems."/boot" = {
    device = "/dev/disk/by-partlabel/nixos-esp";
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
