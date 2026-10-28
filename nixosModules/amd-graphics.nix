{ config, lib, ... }:
{
  config = lib.mkIf (config.oruc.machine.gpu == "amd") {
    hardware.amdgpu.initrd.enable = true;

    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };
  };
}
