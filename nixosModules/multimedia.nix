{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.oruc.machine.features) audioEffects;
  # Qt aborts when EasyEffects starts before the compositor creates the Wayland
  # socket. On 2026-10-21 the unit dumped core twice at login, then the third
  # start worked because the socket existed by then.
  waitForDisplay = pkgs.writeShellScript "easyeffects-wait-display" ''
    set -eu
    runtime="''${XDG_RUNTIME_DIR:?}"
    for _ in {1..50}; do
      if [ -n "''${WAYLAND_DISPLAY:-}" ]; then
        socket=$WAYLAND_DISPLAY
        case $socket in
          /*) ;;
          *) socket=$runtime/$socket ;;
        esac
        if [ -S "$socket" ]; then
          exit 0
        fi
      elif [ -n "''${DISPLAY:-}" ]; then
        case $DISPLAY in
          :*)
            if [ -S "/tmp/.X11-unix/X''${DISPLAY#:}" ]; then
              exit 0
            fi
            ;;
        esac
      fi
      ${lib.getExe' pkgs.coreutils "sleep"} 0.1
    done
    echo "EasyEffects found no display socket." >&2
    exit 1
  '';
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
    ]
    ++ lib.optional config.programs.niri.enable "niri.service";
    wants = [
      "pipewire.service"
      "wireplumber.service"
    ];
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStartPre = [ waitForDisplay ];
      ExecStart = "${lib.getExe pkgs.easyeffects} --service-mode --hide-window";
      Restart = "on-failure";
      RestartSec = 1;
    };
  };
}
