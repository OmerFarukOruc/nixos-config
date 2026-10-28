{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.oruc.recovery.kernelPackages = lib.mkOption {
    type = lib.types.raw;
    default = pkgs.linuxPackages;
    defaultText = lib.literalExpression "pkgs.linuxPackages";
    description = "Kernel package set of the recovery boot entry. A machine whose hardware needs a newer kernel than the stock one picks it here.";
  };

  config.specialisation.recovery.configuration = {
    boot.kernelPackages = lib.mkForce (
      config.oruc.recovery.kernelPackages.extend (import ../kernel-cache/kernel-module-certs.nix lib)
    );
    boot.loader.systemd-boot.sortKey = "o_recovery";
    services.displayManager.sddm.theme = lib.mkForce "";
  };
}
