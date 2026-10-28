{ lib, pkgs, ... }:
let
  sdrBrightness = 400;
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
      After = [ "plasma-workspace.target" ];
      PartOf = [ "plasma-workspace.target" ];
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
