# The node that runs the host's own modules in a NixOS test, as the units test
# and the desktop test use it. Takes the host (a nixosSystem) and the nodes of
# ci/server-units/acme.nix; returns a NixOS module for `nodes.machine`.
{ host, acmeNodes }:
{ lib, ... }:
{
  imports = [
    acmeNodes.client
    ../../nixosModules/default.nix
    { oruc.machine = host.config.oruc.machine; }
    ../../machines/risoluto-dev-1/configuration.nix
    ../../machines/risoluto-dev-1/hardware-configuration.nix
    # Test values for the sops file, as in the boot test.
    ../server-boot/modules/sops.nix
  ];
  virtualisation = {
    # The desktop test raises it.
    memorySize = lib.mkDefault 2048;
    # The host names /dev/vda as Limine's BIOS device, and qemu-vm sets the
    # same option from this one.
    bootLoaderDevice = "/dev/vda";
  };
}
