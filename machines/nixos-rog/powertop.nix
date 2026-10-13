# powertop --auto-tune at boot turns on runtime power saving for every device.
# udev keeps two devices out of it whenever their driver binds, which also
# covers a re-probe after resume.
{ config, ... }:
let
  udevadm = "${config.systemd.package}/bin/udevadm";
in
{
  powerManagement.powertop = {
    enable = true;
    # Reapply the rules below over what auto-tune just set.
    postStart = ''
      ${udevadm} trigger -c bind -s usb -a idVendor=0b05 -a idProduct=19b6
      ${udevadm} trigger -c bind -s pci -a vendor=0x14c3 -a device=0x7925
      # The codec powers down after 1 s of silence and pops when it wakes.
      echo 0 > /sys/module/snd_hda_intel/parameters/power_save
    '';
  };

  services.udev.extraRules = ''
    # The keyboard (USB 0b05:19b6, the Aura device of asus.nix) stays out of
    # autosuspend.
    ACTION=="bind", SUBSYSTEM=="usb", ATTR{idVendor}=="0b05", ATTR{idProduct}=="19b6", TEST=="power/control", ATTR{power/control}="on"
    # The MT7925 Wi-Fi card is the only network link; its ASPM is already off
    # because the link dropped (network.nix).
    ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x14c3", ATTR{device}=="0x7925", TEST=="power/control", ATTR{power/control}="on"
  '';
}
