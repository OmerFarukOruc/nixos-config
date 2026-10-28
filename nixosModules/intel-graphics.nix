{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = lib.mkIf (config.oruc.machine.gpu == "intel") {
    boot.initrd.kernelModules = [ "i915" ];

    hardware.graphics = {
      enable = true;
      enable32Bit = true;
      extraPackages = with pkgs; [
        intel-compute-runtime
        intel-media-driver
        libvdpau-va-gl
        vpl-gpu-rt
      ];
    };
    environment.variables.VDPAU_DRIVER = "va_gl";

    hardware.intel-gpu-tools.enable = true;
  };
}
