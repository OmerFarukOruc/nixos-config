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

  # A boot entry with a stock kernel and the stock greeter, for a generation
  # whose selected kernel or themed greeter does not come up.
  config.specialisation.recovery.configuration = {
    boot.kernelPackages = lib.mkForce config.oruc.recovery.kernelPackages;
    boot.loader.systemd-boot.sortKey = "o_recovery";
    programs.silentSDDM.enable = lib.mkForce false;
  };
}
