{ config, ... }:
let
  udevadm = "${config.systemd.package}/bin/udevadm";
in
{
  powerManagement.powertop = {
    enable = true;
    postStart = ''
      ${udevadm} trigger -c bind -s usb -a bInterfaceClass=03
      ${udevadm} trigger -c bind -s usb -a devpath=0
      ${udevadm} trigger -c bind -s pci -a vendor=0x14c3 -a device=0x7925
      echo 0 > /sys/module/snd_hda_intel/parameters/power_save
    '';
  };

  services.udev.extraRules = ''
    ACTION=="bind", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_interface", ATTR{bInterfaceClass}=="03", TEST=="../power/control", ATTR{../power/control}="on"
    ACTION=="bind", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{devpath}=="0", TEST=="power/wakeup", ATTR{power/wakeup}="enabled"
    ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x14c3", ATTR{device}=="0x7925", TEST=="power/control", ATTR{power/control}="on"
  '';
}
