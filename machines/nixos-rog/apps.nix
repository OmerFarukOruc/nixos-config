{ config, pkgs, ... }:
{
  virtualisation.docker.enableOnBoot = false;
  virtualisation.podman.enable = true;
  hardware.nvidia-container-toolkit.enable = true;
  hardware.cpu.amd.ryzen-smu.enable = true;

  environment.systemPackages = [
    # keep-sorted start
    config.boot.kernelPackages.turbostat
    pkgs.efibootmgr
    pkgs.powertop
    pkgs.ryzenadj
    # keep-sorted end
  ];
}
