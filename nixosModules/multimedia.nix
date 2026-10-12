{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.oruc.machine.features) audioEffects;
in
lib.mkIf (config.oruc.machine.kind == "workstation") {
  security.rtkit.enable = true;

  services.pipewire = {
    enable = true;
    alsa = {
      enable = true;
      support32Bit = true;
    };
    pulse.enable = true;
    wireplumber.enable = true;
  };

  programs.dconf.enable = true;
  xdg.portal.enable = true;

  environment.systemPackages = [
    # vainfo and vdpauinfo show which video decoders each GPU offers.
    pkgs.libva-utils
    pkgs.vdpauinfo
  ]
  ++ lib.optional audioEffects pkgs.easyeffects;
  systemd.user.services.easyeffects = lib.mkIf audioEffects {
    description = "EasyEffects PipeWire effects service";
    after = [
      "pipewire.service"
      "wireplumber.service"
    ];
    wants = [
      "pipewire.service"
      "wireplumber.service"
    ];
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${lib.getExe pkgs.easyeffects} --service-mode --hide-window";
      Restart = "on-failure";
    };
  };
}
