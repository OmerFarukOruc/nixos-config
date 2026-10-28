{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  hushmic =
    (inputs.hushmic.packages.${pkgs.stdenv.hostPlatform.system}.hushmic.override {
      xorg = {
        libX11 = pkgs.libx11;
        libXcursor = pkgs.libxcursor;
        libXi = pkgs.libxi;
        libXrandr = pkgs.libxrandr;
        inherit (pkgs) libxcb;
      };
    }).overrideAttrs
      (old: {
        # rog's Nix daemon builds under SCHED_BATCH (nix.daemonCPUSchedPolicy), and
        # this test expects a new thread to start under SCHED_OTHER. Its failure
        # poisons a lock that three other rt tests share, so they fail with it.
        checkFlags = (old.checkFlags or [ ]) ++ [
          "--skip=rt::tests::timeshare_data_loop_in_this_process_never_requests_a_policy_change"
        ];
      });
  settings = (pkgs.formats.toml { }).generate "hushmic-config.toml" {
    enabled = true;
    inherit (import ./audio-nodes.nix) mic;
    model = "dpdfnet8_48khz_hr";
    attn_limit = 100;
    inference = "auto";
    set_default = false;
    autostart = false;
    tray = false;
  };
in
{
  home.packages = [ hushmic ];

  systemd.user.services.hushmic = {
    Unit = {
      Description = "HushMic microphone noise suppression";
      After = [
        "pipewire.service"
        "wireplumber.service"
        "easyeffects.service"
        "graphical-session.target"
      ];
      Wants = [
        "pipewire.service"
        "wireplumber.service"
      ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      # HushMic writes its state back into this file, so it is a copy, not a
      # store link. Each start resets it to these settings.
      ExecStartPre = "${lib.getExe' pkgs.coreutils "install"} -Dm600 ${settings} ${config.xdg.configHome}/hushmic/config.toml";
      ExecStart = "${lib.getExe hushmic} --headless";
      Restart = "on-failure";
      RestartSec = 3;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
