{ lib, ... }:
{
  systemd.timers.nightly-update.enable = lib.mkForce false;
}
