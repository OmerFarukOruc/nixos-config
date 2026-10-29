{ host, acmeNodes }:
{ lib, ... }:
{
  imports = [
    acmeNodes.client
    ../../nixosModules/default.nix
    { oruc.machine = host.config.oruc.machine; }
    ../../machines/devbox/configuration.nix
    ../../machines/devbox/hardware-configuration.nix
    ../server-boot/modules/sops.nix
  ];
  virtualisation = {
    memorySize = lib.mkDefault 2048;
    bootLoaderDevice = "/dev/vda";
  };
}
