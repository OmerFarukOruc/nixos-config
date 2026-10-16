let
  launcherSpecs = {
    anyrun.desktops = [ "niri" ];
    fuzzel.desktops = [ "niri" ];
    rofi.desktops = [
      "niri"
      "plasma"
    ];
    vicinae.desktops = [ "niri" ];
    walker.desktops = [ "niri" ];
  };

  # package is the attribute path in pkgs of the kernel package set.
  # requiresModule is a kernel module that the hardware scan lists only on a CPU
  # that can run the build.
  kernelSpecs = {
    nixos = {
      package = [ "linuxPackages" ];
      requiresModule = null;
    };
    cachyos-latest-lto-x86_64-v3 = {
      package = [
        "cachyosKernels"
        "linuxPackages-cachyos-latest-lto-x86_64-v3"
      ];
      requiresModule = null;
    };
    # -march=znver4; runs only on Zen 4 and newer AMD CPUs. kvm-amd appears only
    # on an AMD CPU, so an AMD CPU older than Zen 4 still passes the check.
    cachyos-latest-lto-zen4 = {
      package = [
        "cachyosKernels"
        "linuxPackages-cachyos-latest-lto-zen4"
      ];
      requiresModule = "kvm-amd";
    };
  };

  # A shell owns the bar, notifications, wallpaper, and the compositor binds
  # that call into it.
  shellSpecs = {
    dms.desktops = [ "niri" ];
    noctalia.desktops = [ "niri" ];
    plasma.desktops = [ "plasma" ];
    waybar.desktops = [ "niri" ];
  };

  # Each Plasma look is a file of the same name in
  # home-manager/modules/plasma-looks/.
  plasmaLookNames = [
    "glass"
    "klassy"
    "tiling"
  ];
in
{
  inherit
    kernelSpecs
    launcherSpecs
    plasmaLookNames
    shellSpecs
    ;
  kernelNames = builtins.attrNames kernelSpecs;
  launcherNames = builtins.attrNames launcherSpecs;
  shellNames = builtins.attrNames shellSpecs;
}
