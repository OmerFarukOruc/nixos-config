# Hybrid graphics: the Radeon 890M renders the desktop and the RTX 4070 sleeps
# until a program is offloaded to it. The firmware must be in Hybrid mode
# (asus-armoury dgpu_disable=0, gpu_mux_mode=1); in Integrated mode the RTX 4070
# is not on the PCI bus at all.
{ config, lib, ... }:
let
  radeonRenderNode = import ./radeon-render-node.nix;
in
{
  # Neither GPU has boot_vga set, so niri renders on whichever one udev lists
  # first. When that is the RTX 4070, niri, its shell and Xwayland hold it
  # awake for the whole session.
  environment.etc."niri/host.kdl".text = ''
    debug {
        render-drm-device "${radeonRenderNode}"
    }
  '';

  # The NixOS NVIDIA module turns on only when "nvidia" is listed here, also on
  # Wayland. The iGPU driver comes first so nothing keeps the dGPU awake.
  services.xserver.videoDrivers = [
    "amdgpu"
    "nvidia"
  ];

  oruc.verifyFacts.nvidia_version = config.hardware.nvidia.package.version;

  hardware.nvidia = {
    open = true;
    # The kernel overlay's own nvidiaPackages.latest is 610.57.04, and its
    # patch for latest.open broke 615 until a fix after our pin; a mkDriver
    # package skips that patch. Drop this once nvidiaPackages.latest in
    # flake.lock is this version or newer. kernel-cache/flake.nix builds the
    # open module with the same arguments, so change both together.
    # Driver hashes: nix-prefetch-url of NVIDIA's .run and of the GitHub tags of
    # open-gpu-kernel-modules, nvidia-settings and nvidia-persistenced.
    package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
      version = "615.78.08";
      sha256_64bit = "sha256-Pj9t3cLudnoIGFMAr3vjyyhuznZpjS3eNSRZl4LQf/4=";
      openSha256 = "sha256-HBINiOjL0ZJLIAJeNIBYHBnwgUXtNwPPtnFpAI1YwF4=";
      settingsSha256 = "sha256-inDRpG02sdDgHmlqgu/DsgK8OFdOt1fZIYyXdhlGC/c=";
      persistencedSha256 = "sha256-RzeR6Ldct6MUxjnXRyThdh5Y3jjMehTVg85MtwuWNX4=";
      # Defers the NVPCF ACPI notify that the firmware sends on every 1 %
      # battery drop, which otherwise wakes the suspended RTX 4070 for about
      # 20 s. The files are the two commits of
      # https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1299, kept in
      # the repository so a rewritten pull request cannot break a rebuild.
      # kernel-cache/flake.nix builds the cached module from the same files.
      # Drop them once an NVIDIA release contains the change.
      patchesOpen = [
        ../../kernel-cache/patches/nvidia-nvpcf-refcount.patch
        ../../kernel-cache/patches/nvidia-nvpcf-defer.patch
      ];
    };

    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true;
      };
      # lspci 0000:66:00.0 and 0000:65:00.0, in decimal.
      amdgpuBusId = "PCI:102@0:0:0";
      nvidiaBusId = "PCI:101@0:0:0";
    };

    # Saves video memory across suspend. With the open module at 595 or newer,
    # NixOS uses the kernel's suspend notifiers instead of nvidia-suspend units.
    powerManagement.enable = true;
    # Runtime D3: the dGPU powers off when nothing uses it.
    powerManagement.finegrained = true;
    # nvidia-powerd raises the GPU power limit above its 55 W base up to the
    # TGP and boost that asusd sets; without it the limit stays at 55 W.
    dynamicBoost.enable = true;
  };
  # asusd starts nvidia-powerd when AC is plugged in and stops it when AC is
  # unplugged, but never at its own start, so a boot on battery skips it here.
  systemd.services.nvidia-powerd.unitConfig.ConditionACPower = true;

  # The binary cache holds the NVIDIA module only for the selected kernel, so
  # the recovery kernel would compile it on the machine; the recovery entry
  # drops the driver instead. Without it, NixOS no longer blacklists nouveau.
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
    # s2idle is this laptop's only sleep state. CachyOS set this; the suspend
    # gate in the install runbook decides whether it stays.
    "nvidia.NVreg_EnableS0ixPowerManagement=1"
  ];
}
