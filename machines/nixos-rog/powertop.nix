# powertop --auto-tune at boot turns on runtime power saving for every device.
# udev keeps USB input devices and the Wi-Fi card out of it, and lets USB
# devices wake the system, whenever their driver binds, which also covers a
# re-probe after resume.
{ config, ... }:
let
  udevadm = "${config.systemd.package}/bin/udevadm";
in
{
  powerManagement.powertop = {
    enable = true;
    # Reapply the rules below over what auto-tune just set.
    postStart = ''
      ${udevadm} trigger -c bind -s usb -a bInterfaceClass=03
      ${udevadm} trigger -c bind -s usb -a devpath=0
      ${udevadm} trigger -c bind -s pci -a vendor=0x14c3 -a device=0x7925
      # The codec powers down after 1 s of silence and pops when it wakes.
      echo 0 > /sys/module/snd_hda_intel/parameters/power_save
    '';
  };

  services.udev.extraRules = ''
    # A USB device with a HID interface, such as the keyboard (the Aura
    # device of asus.nix) or a mouse, stays awake. Under auto-tune a mouse
    # suspended 2 s after it stopped moving, and the pointer froze for about
    # a second when it moved again. The rule matches the interface, so it
    # sets the power control of the device above it.
    ACTION=="bind", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_interface", ATTR{bInterfaceClass}=="03", TEST=="../power/control", ATTR{../power/control}="on"
    # auto-tune turns off wakeup on the USB root hubs (devpath 0). This keeps
    # the kernel's default, on, so the keyboard and a USB mouse can wake the
    # system from sleep.
    ACTION=="bind", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{devpath}=="0", TEST=="power/wakeup", ATTR{power/wakeup}="enabled"
    # The MT7925 Wi-Fi card is the only network link; its ASPM is already off
    # because the link dropped (network.nix).
    ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x14c3", ATTR{device}=="0x7925", TEST=="power/control", ATTR{power/control}="on"
  '';
}
