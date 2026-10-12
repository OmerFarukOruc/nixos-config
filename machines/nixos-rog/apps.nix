# Container runtimes and AMD power tools that only nixos-rog installs.
{ config, pkgs, ... }:
{
  # docker.socket starts the daemon on first use, which keeps
  # NetworkManager-wait-online out of the boot path.
  virtualisation.docker.enableOnBoot = false;
  # Rootless, without the Docker-compatible socket, so Docker keeps its own.
  virtualisation.podman.enable = true;
  hardware.nvidia-container-toolkit.enable = true;
  # ryzenadj reads and sets the package power limits through this module.
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
