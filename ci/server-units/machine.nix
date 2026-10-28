{ host, acmeNodes }:
{ lib, ... }:
{
  imports = [
    acmeNodes.client
    ../../nixosModules/default.nix
    { oruc.machine = host.config.oruc.machine; }
    ../../machines/risoluto-dev-1/configuration.nix
    ../../machines/risoluto-dev-1/hardware-configuration.nix
    ../server-boot/modules/sops.nix
  ];
  virtualisation = {
    memorySize = lib.mkDefault 2048;
    bootLoaderDevice = "/dev/vda";
  };
}
