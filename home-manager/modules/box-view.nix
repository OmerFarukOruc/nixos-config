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
      [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] || {
        echo "box-view: $host is not a host name." >&2
        exit 2
      }
      display="127.0.0.1::${toString boxBrowserVncPort}"

      if [[ $host != local && $host != "$(uname -n)" ]]; then
        tunnel_dir=$(mktemp -d "''${XDG_RUNTIME_DIR:?}/box-view.XXXXXX")
        display=$tunnel_dir/vnc.sock
        ssh -N -o ExitOnForwardFailure=yes -o BatchMode=yes -o ConnectTimeout=10 \
          -L "$display:127.0.0.1:${toString boxBrowserVncPort}" -- "$host" 2> "$tunnel_dir/ssh.log" &
        tunnel=$!
        trap 'kill "$tunnel" 2> /dev/null || true; rm -rf "$tunnel_dir"' EXIT
        for _ in {1..150}; do
          [[ -S $display ]] && break
          kill -0 "$tunnel" 2> /dev/null || break
          sleep 0.1
        done
        if [[ ! -S $display ]]; then
          reason=$(tail -n 1 "$tunnel_dir/ssh.log")
          echo "box-view: the SSH tunnel to $host did not come up: ''${reason:-no socket after 15 s}" >&2
          notify-send --app-name=box-view --icon=dialog-error "Box browser" "The SSH tunnel to $host did not come up." || true
          exit 1
        fi
      fi

      rc=0
      vncviewer -Log '*:stderr:0' "$display" || rc=$?
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
