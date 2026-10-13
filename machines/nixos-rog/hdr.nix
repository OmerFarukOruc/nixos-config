# The Samsung ATNA60DL04-0 OLED panel runs in HDR under Plasma. KWin keeps
# these values in ~/.config/kwinoutputconfig.json, which it rewrites itself, so
# this service applies them at each Plasma login instead. niri has no HDR.
#
# The panel's EDID: 10-bit, DCI-P3 primaries with the PQ (SMPTE ST 2084)
# transfer, 617 nits peak, 400 nits frame average, and 400 nits as its maximum
# suggested SDR luminance. KWin reads the peak from the EDID, so no override.
{ lib, pkgs, ... }:
let
  # SDR white in nits: the panel's suggested SDR maximum. A higher value
  # exceeds its frame-average limit. Each login sets it back to this value.
  sdrBrightness = 400;
  # How far SDR colours stretch into the panel's gamut, in percent. Display
  # settings calls it sRGB color intensity.
  sdrGamut = 100;
  apply = pkgs.writeShellApplication {
    name = "oruc-plasma-hdr";
    runtimeInputs = [
      pkgs.jq
      pkgs.kdePackages.libkscreen
    ];
    text = ''
      # The panel's connector is eDP-1 or eDP-2, depending on driver probe order.
      # kscreen-doctor's JSON has no SDR gamut field, so every login applies
      # all the values.
      kscreen-doctor -j \
        | jq -r '.outputs[]
            | select(.connected and .enabled and (.name | startswith("eDP")))
            | .name' \
        | while read -r name; do
            kscreen-doctor "output.$name.hdr.enable" "output.$name.wcg.enable" \
              "output.$name.sdr-brightness.${toString sdrBrightness}" \
              "output.$name.sdrGamut.${toString sdrGamut}"
          done
    '';
  };
in
{
  systemd.user.services.oruc-plasma-hdr = {
    Unit = {
      Description = "Turn on HDR for the laptop panel";
      # Only a Plasma session reaches plasma-workspace.target.
      After = [ "plasma-workspace.target" ];
      PartOf = [ "plasma-workspace.target" ];
      # Stop retrying when KWin keeps rejecting the change.
      StartLimitIntervalSec = 60;
      StartLimitBurst = 3;
    };
    Service = {
      Type = "oneshot";
      ExecStart = lib.getExe apply;
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "plasma-workspace.target" ];
  };
}
