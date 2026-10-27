# A netcup KVM guest with one virtio disk. The initrd modules are the set that
# nixos-generate-config writes for a QEMU guest; the file systems come from
# disk.nix.
{ lib, ... }:
{
  boot.initrd.availableKernelModules = [
    "ahci"
    "xhci_pci"
    "virtio_pci"
    "virtio_scsi"
    "virtio_blk"
    "sr_mod"
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
