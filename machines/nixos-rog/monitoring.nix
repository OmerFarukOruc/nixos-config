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
