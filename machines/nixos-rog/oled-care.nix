# The OLED panel shows the top bar and the dock in the same place all day. The
# pixel shift of the macOS Tahoe theme moves each Plasma panel by 2 px every
# 5 minutes, up to 8 px each way and back: a panel that fills the screen's
# width, such as the top bar, grows in height, and the others, such as the dock,
# move sideways. It keeps each panel's base geometry in
# ~/.local/state/mac-tahoe-liquid-kde/oled-care.json, and takes a panel's
# current geometry as its new base when it differs from the last shift, as
# after plasma-manager builds the panels again.
{ inputs, pkgs, ... }:
let
  inherit (inputs.mac-tahoe.lib.mkPackages pkgs) tools;
in
{
  # For mac-tahoe-oled-care status and restore by hand. The tools package
  # also holds the theme's switcher, which would restyle the whole desktop,
  # so only this command is installed.
  home.packages = [
    (pkgs.runCommand "mac-tahoe-oled-care" { } ''
      mkdir -p $out/bin
      ln -s ${tools}/bin/mac-tahoe-oled-care $out/bin/
    '')
  ];

  systemd.user.services.oled-care = {
    Unit = {
      Description = "Shift the Plasma panels by a few pixels";
      After = [ "plasma-workspace.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${tools}/bin/mac-tahoe-oled-care shift --max-px 8";
    };
  };

  # Only a Plasma session reaches plasma-workspace.target, so niri has no shift.
  systemd.user.timers.oled-care = {
    Unit = {
      Description = "Shift the Plasma panels every 5 minutes";
      PartOf = [ "plasma-workspace.target" ];
    };
    Timer.OnCalendar = "*:0/5";
    Install.WantedBy = [ "plasma-workspace.target" ];
  };
}
