# A Radeon as the only GPU. Mesa's radeonsi already gives OpenGL, Vulkan and
# VA-API, so this adds the 32-bit drivers, an early driver load and vainfo.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf (config.oruc.machine.gpu == "amd") {
    # The boot screen gets the monitor's own mode from the start.
    hardware.amdgpu.initrd.enable = true;

    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };

    environment.systemPackages = [ pkgs.libva-utils ];
  };
}
