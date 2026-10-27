# A desktop popup when one of rog's own unattended units fails, through the
# notify-failure@ unit of nixosModules/monitoring.nix. Each unit must stay
# enabled, or NixOS writes a unit with no ExecStart=, which systemd refuses.
{ lib, ... }:
{
  systemd.services =
    lib.genAttrs
      [
        "oruc-cpu-limits"
        "oruc-low-battery"
        "usque"
      ]
      (_: {
        onFailure = [ "notify-failure@%p.service" ];
      });
}
