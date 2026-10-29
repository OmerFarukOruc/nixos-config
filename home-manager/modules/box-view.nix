{ lib, pkgs, ... }:
let
  defaultHost = "devbox";
  boxBrowserVncPort = 5920;

  boxView = pkgs.writeShellApplication {
    name = "box-view";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.iproute2
      pkgs.libnotify
      pkgs.openssh
      pkgs.tigervnc
    ];
    text = ''
      host=''${1:-${defaultHost}}
      first_port=5920
      last_port=5939
      tunnel_pid=
      log=$(mktemp)

      fail() {
        echo "box-view: $1" >&2
        notify-send --app-name=box-view --icon=dialog-error "Box browser" "$1" || true
        exit 1
      }

      cleanup() {
        if [[ -n $tunnel_pid ]]; then
          kill "$tunnel_pid" 2>/dev/null || true
          wait "$tunnel_pid" 2>/dev/null || true
        fi
        rm -f -- "$log"
      }
      trap cleanup EXIT
      trap 'exit 130' INT TERM HUP

      # ss only reads the socket table. A probe that connected to the tunnel
      # would reach Xvnc and drop, and Xvnc counts that as a failed login and
      # blocks the host after a few of them.
      listening() { [[ -n $(ss -Htln "sport = :$1") ]]; }

      port=$first_port
      while listening "$port"; do
        port=$((port + 1))
        ((port <= last_port)) || fail "No free local port from $first_port to $last_port."
      done

      ssh -N -o ExitOnForwardFailure=yes -o BatchMode=yes -o ConnectTimeout=10 \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
        -L "127.0.0.1:$port:127.0.0.1:${toString boxBrowserVncPort}" "omer@$host" \
        </dev/null 2>"$log" &
      tunnel_pid=$!

      up=false
      for _ in {1..30}; do
        kill -0 "$tunnel_pid" 2>/dev/null || break
        if listening "$port"; then
          up=true
          break
        fi
        sleep 0.5
      done
      if [[ $up == false ]]; then
        reason=$(tail -n 1 -- "$log")
        fail "The SSH tunnel to $host did not come up: ''${reason:-no answer in 15 seconds}"
      fi

      rc=0
      vncviewer -Log '*:stderr:0' "127.0.0.1::$port" || rc=$?
      if ((rc != 0)); then
        notify-send --app-name=box-view --icon=dialog-error "Box browser" "The viewer exited with status $rc." || true
        exit "$rc"
      fi
    '';
  };
in
{
  home.packages = [ boxView ];

  xdg.desktopEntries.box-view = {
    name = "Box browser";
    comment = "Sign in to sites in the shared browser on ${defaultHost}";
    exec = lib.getExe boxView;
    icon = "chromium";
    terminal = false;
    categories = [
      "Network"
      "WebBrowser"
    ];
  };
}
