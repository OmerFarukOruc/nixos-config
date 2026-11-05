{
  config,
  lib,
  ...
}:
let
  radeonRenderNode = import ./radeon-render-node.nix;
in
{
  # Neither GPU has boot_vga set, so niri renders on whichever one udev lists
  # first. When that is the RTX 4070, niri, its shell and Xwayland hold it
  # awake for the whole session. nixosModules/desktop.nix and asus.nix also
  # write /etc/niri/host.kdl; the text of the three merges, and config.kdl
  # includes the result.
  environment.etc."niri/host.kdl".text = ''
    debug {
        render-drm-device "${radeonRenderNode}"
    }
  '';

  # In automatic mode Sunshine tried NVENC first, which failed without CUDA but
  # left it holding the RTX 4070 open, and then encoded on the Radeon through
  # Vulkan. These settings go straight to the Radeon.
  services.sunshine.settings = lib.mkIf config.services.sunshine.enable {
    encoder = "vulkan";
    adapter_name = radeonRenderNode;
  };
  systemd.user.services.sunshine = lib.mkIf config.services.sunshine.enable {
    environment.VK_LOADER_DRIVERS_SELECT = "*radeon*";
  };

  # The NixOS NVIDIA module turns on only when "nvidia" is listed here, also on
  # Wayland. The iGPU driver comes first so nothing keeps the dGPU awake.
  services.xserver.videoDrivers = [
    "amdgpu"
    "nvidia"
  ];

  oruc.verifyFacts.nvidia_version = config.hardware.nvidia.package.version;

  hardware.nvidia = {
    open = true;
    package = config.boot.kernelPackages.nvidiaPackages.mkDriver (import ./nvidia-driver.nix);

    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true;
      };
      amdgpuBusId = "PCI:102@0:0:0";
      nvidiaBusId = "PCI:101@0:0:0";
    };

    # Saves video memory across suspend. With the open module at 595 or newer,
    # NixOS uses the kernel's suspend notifiers instead of nvidia-suspend units.
    powerManagement.enable = true;
    powerManagement.finegrained = true;
    dynamicBoost.enable = true;
  };
  # asusd starts nvidia-powerd when AC is plugged in and stops it when AC is
  # unplugged, but never at its own start, so a boot on battery skips it here.
  systemd.services.nvidia-powerd.unitConfig.ConditionACPower = true;

  # Each kernel needs its own NVIDIA module build, so the recovery entry drops
  # the driver instead of compiling a second module on the laptop. Without it,
  # NixOS no longer blacklists nouveau.
  specialisation.recovery.configuration = {
    services.xserver.videoDrivers = lib.mkForce (
      lib.remove "nvidia" config.services.xserver.videoDrivers
    );
    hardware.nvidia-container-toolkit.enable = lib.mkForce false;
    boot.blacklistedKernelModules = [ "nouveau" ];
  };

  boot.kernelParams = [
    # The video memory saved at suspend goes to disk, never to a RAM-backed /tmp.
    "nvidia.NVreg_TemporaryFilePath=/var/tmp"
    "nvidia.NVreg_EnableS0ixPowerManagement=1"
  ];

  # The HDR Plasma session keeps the panel's backlight at 100 of 400000, so
  # systemd-backlight saves 100 at shutdown. Its default floor of 1% leaves the
  # login screen black on this OLED panel.
  services.udev.extraRules = ''
    ACTION!="remove", SUBSYSTEM=="backlight", KERNEL=="amdgpu_bl*", ENV{ID_BACKLIGHT_CLAMP}="30%%"
  '';
}
