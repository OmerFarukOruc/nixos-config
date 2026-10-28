{
  config,
  lib,
  pkgs,
  ...
}:
let
  radeonRenderNode = import ./radeon-render-node.nix;
  nvidiaDriver = config.boot.kernelPackages.nvidiaPackages.mkDriver (
    import ../../kernel-cache/nvidia-driver.nix
  );
  driverPatchelf = config.boot.kernelPackages.callPackage ({ patchelf }: patchelf) { };
in
{
  nixpkgs.overlays = [ (import ../../overlays/nvidia-patchelf.nix) ];

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

  # A monitor on the HDMI port, which the RTX 4070 drives, shows KWin's frames
  # after KWin copies them from the Radeon. KWin 6.8.1 makes that copy with EGL
  # and presents before it finishes, so the monitor flickers and shows partly
  # drawn windows. The variable brings back the Vulkan copy, which 6.8.2 uses
  # again by default
  # (https://invent.kde.org/plasma/kwin/-/commit/83ad3261da595f02b4dadbc14d00223ffae0d72c).
  # A login session reads it at login.
  environment.sessionVariables = lib.mkIf (lib.versionOlder pkgs.kdePackages.kwin.version "6.8.2") {
    KWIN_ALLOW_VULKAN_MGPU_COPIES = "1";
  };

  services.xserver.videoDrivers = [
    "amdgpu"
    "nvidia"
  ];

  oruc.verifyFacts.nvidia_version = config.hardware.nvidia.package.version;

  hardware.nvidia = {
    open = true;
    # nvidiaPackages.latest in flake.lock (the kernel overlay's nixpkgs is node
    # nixpkgs_2) is older than this version. Drop this block once it is this
    # version or newer. The cache and host import the same driver arguments.
    # patchelf 0.15.2 while the driver's package set has 0.19.2
    # (overlays/nvidia-patchelf.nix); the condition skips the override once
    # that package set moves to another patchelf. The open kernel module is a
    # passthru of the driver, so the override keeps the module that the
    # kernel-cache workflow builds.
    package =
      if driverPatchelf.version == "0.19.2" then
        nvidiaDriver.overrideAttrs (old: {
          nativeBuildInputs = [ pkgs.patchelf_0_15 ] ++ old.nativeBuildInputs;
        })
      else
        nvidiaDriver;

    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true;
      };
      amdgpuBusId = "PCI:102@0:0:0";
      nvidiaBusId = "PCI:101@0:0:0";
    };

    powerManagement.enable = true;
    powerManagement.finegrained = true;
    dynamicBoost.enable = true;
  };
  systemd.services.nvidia-powerd.unitConfig.ConditionACPower = true;

  specialisation.recovery.configuration = {
    services.xserver.videoDrivers = lib.mkForce (
      lib.remove "nvidia" config.services.xserver.videoDrivers
    );
    hardware.nvidia-container-toolkit.enable = lib.mkForce false;
    boot.blacklistedKernelModules = [ "nouveau" ];
  };

  boot.kernelParams = [
    "nvidia.NVreg_TemporaryFilePath=/var/tmp"
    "nvidia.NVreg_EnableS0ixPowerManagement=1"
  ];
}
