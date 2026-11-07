{
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  defaultHost = if osConfig.oruc.machine.features.boxBrowser then "local" else "devbox";
  boxBrowserVncPort = 5920;

  boxView = pkgs.writeShellApplication {
    name = "box-view";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.libnotify
      pkgs.openssh
      pkgs.tigervnc
    ];
    text = ''
      host=''${1:-${defaultHost}}
      display="127.0.0.1::${toString boxBrowserVncPort}"

      args=(-Log '*:stderr:0')
      if [[ $host != local && $host != "$(uname -n)" ]]; then
        # vncviewer runs this through sh with L, H, R and G set: the local port,
        # the VNC host and port as the gateway sees them, and the gateway.
        # shellcheck disable=SC2016
        export VNC_VIA_CMD='ssh -f -o ExitOnForwardFailure=yes -o BatchMode=yes -o ConnectTimeout=10 -L "$L":"$H":"$R" "$G" sleep 20'
        args+=(-via "$host")
      fi

      rc=0
      vncviewer "''${args[@]}" "$display" || rc=$?
      if ((rc != 0)); then
        echo "box-view: the viewer for $host exited with status $rc." >&2
        notify-send --app-name=box-view --icon=dialog-error "Box browser" "The viewer for $host exited with status $rc." || true
        exit "$rc"
      fi
    '';
  };
in
{
  home.packages = [ boxView ];

  xdg.desktopEntries.box-view = {
    name = "Box browser";
    comment = "Sign in to sites in the agents' shared browser";
    exec = lib.getExe boxView;
    icon = "chromium";
    terminal = false;
    categories = [
      "Network"
      "WebBrowser"
    ];
  };
}
