# Disk health: smartd watches every disk and logs to the journal. With
# features.diskSelfTests it also runs a short self-test daily at 02:00 and a
# long one on Sundays at 03:00.
{ config, lib, ... }:
{
  services.smartd = {
    enable = true;
    autodetect = true;
    defaults.autodetected = lib.mkIf config.oruc.machine.features.diskSelfTests "-a -o on -S on -s (S/../.././02|L/../../7/03)";
  };
}
