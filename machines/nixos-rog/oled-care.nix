{ inputs, pkgs, ... }:
let
  inherit (inputs.mac-tahoe.lib.mkPackages pkgs) tools;
  oledCare = "${tools}/bin/mac-tahoe-oled-care";
in
{
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
      ExecStart = "${pkgs.writeShellScript "oled-care-shift" ''
        if ! state=$(${oledCare} status 2>&1) && [[ $state == "recovery pending"* ]]; then
          echo "$state; restoring the panels"
          ${oledCare} restore || exit 1
        fi
        exec ${oledCare} shift --max-px 8
      ''}";
    };
  };

  systemd.user.timers.oled-care = {
    Unit = {
      Description = "Shift the Plasma panels every 5 minutes";
      PartOf = [ "plasma-workspace.target" ];
    };
    Timer.OnCalendar = "*:0/5";
    Install.WantedBy = [ "plasma-workspace.target" ];
  };
}
