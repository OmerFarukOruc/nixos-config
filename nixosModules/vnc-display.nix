{ lib, pkgs }:
{
  number,
  vncPort,
  desktopName,
  description,
  user,
  wantedBy,
  sessionEdges,
}:
let
  display = ":${toString number}";

  prepare = pkgs.writeShellApplication {
    name = "vnc-display-prepare";
    runtimeInputs = [
      pkgs.util-linux
      pkgs.xauth
    ];
    text = ''
      printf 'remove %s\nadd %s . %s\n' "$1" "$1" "$(mcookie)" | xauth -f "$HOME/.Xauthority" source -
    '';
  };

  # Xvnc sends no readiness signal, so its clients wait for its socket.
  waitForSocket = pkgs.writeShellApplication {
    name = "vnc-display-wait";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      for _ in {1..30}; do
        [[ -S /tmp/.X11-unix/X$1 ]] && exit 0
        sleep 1
      done
      echo "The X socket of display :$1 did not appear." >&2
      exit 1
    '';
  };
in
{
  inherit display;
  environment = {
    DISPLAY = display;
    XAUTHORITY = "%h/.Xauthority";
  };
  waitCommand = "${lib.getExe waitForSocket} ${toString number}";
  service = {
    inherit description wantedBy;
    partOf = sessionEdges;
    after = sessionEdges;
    unitConfig = {
      ConditionUser = user;
      StartLimitIntervalSec = 0;
    };
    serviceConfig = {
      ExecStartPre = "${lib.getExe prepare} ${display}";
      ExecStart = lib.concatStringsSep " " [
        (lib.getExe' pkgs.tigervnc "Xvnc")
        display
        "-auth %h/.Xauthority"
        "-localhost"
        "-rfbport ${toString vncPort}"
        "-nolisten tcp"
        "-SecurityTypes None"
        "-desktop ${desktopName}"
        "-geometry 1920x1080"
        "-depth 24"
        "-AlwaysShared"
      ];
      Restart = "always";
      RestartSec = 2;
    };
  };
}
