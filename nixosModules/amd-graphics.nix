# A Radeon as the only GPU. hardware.graphics.enable installs Mesa (radeonsi
# for OpenGL and VA-API, RADV for Vulkan); this adds the 32-bit drivers and an
# early driver load. vainfo comes with every workstation (multimedia.nix).
{ config, lib, ... }:
{
  config = lib.mkIf (config.oruc.machine.gpu == "amd") {
    # The boot screen gets the monitor's own mode from the start.
    hardware.amdgpu.initrd.enable = true;

    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };
  };
}
