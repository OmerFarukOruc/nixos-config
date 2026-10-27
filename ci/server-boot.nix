# This file defines the boot test of risoluto-dev-1. It runs disko's
# makeDiskoTest (a NixOS VM test) on the host's own configuration. A VM installs the host's disk layout and system,
# including Limine's BIOS stage, reboots from the disk without QEMU's kernel
# loader, and runs the checks below. efi = false boots the disk through SeaBIOS
# and efi = true through OVMF. Build it with
# scripts/build-on-rog.sh .#checks.x86_64-linux.risoluto-dev-1-boot-bios (or
# -uefi); Nix caches the result until the host or the test changes.
#
# Extend it without editing this file:
# - ci/server-boot/checks/*.py hold the Python checks, run in path order on
#   `machine` after it boots. `efi` is True under OVMF. The files share one
#   Python namespace.
# - ci/server-boot/modules/*.nix are NixOS modules that only the test machine
#   loads, such as test values for the sops file or a stub of an external
#   service.
# - ci/server-boot/secrets.yaml holds the test values of the sops keys.
#
# Takes the inputs and the host (a nixosSystem); returns the flake checks.
{ inputs, host }:
let
  inherit (inputs.nixpkgs) lib;
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  inherit (inputs.disko.lib.testLib) makeDiskoTest;

  filesIn = suffix: dir: lib.filter (lib.hasSuffix suffix) (lib.filesystem.listFilesRecursive dir);

  boot =
    { name, efi }:
    makeDiskoTest {
      name = "risoluto-dev-1-${name}";
      inherit pkgs efi;
      inherit (host) extendModules;
      disko-config = ../machines/risoluto-dev-1/disk.nix;
      # The disks of the installer VM hold 4 GiB each, and the host's ESP alone
      # is 4 GiB. The image is sparse.
      extraInstallerConfig.virtualisation.emptyDiskImages = lib.mkForce [ 16384 ];
      extraSystemConfig =
        { config, ... }:
        {
          imports = filesIn ".nix" ./server-boot/modules;
          # The installer VM sees the target disk as /dev/vdb, and
          # makeDiskoTest moves GRUB's device there but not Limine's.
          boot.loader.limine.biosDevice = lib.mkOverride 70 (lib.head config.boot.loader.grub.devices);
        };
      extraTestScript = lib.concatStringsSep "\n" (
        [ "efi = ${if efi then "True" else "False"}" ]
        ++ map builtins.readFile (filesIn ".py" ./server-boot/checks)
      );
    };
in
{
  risoluto-dev-1-boot-bios = boot {
    name = "bios";
    efi = false;
  };
  risoluto-dev-1-boot-uefi = boot {
    name = "uefi";
    efi = true;
  };
}
