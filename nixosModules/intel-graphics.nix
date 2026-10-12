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
        # VDPAU through VA-API, for players that only speak VDPAU.
        libvdpau-va-gl
        vpl-gpu-rt
      ];
    };
    environment.variables.VDPAU_DRIVER = "va_gl";

    # intel_gpu_top, with the capability it needs to read the GPU counters.
    hardware.intel-gpu-tools.enable = true;
  };
}
