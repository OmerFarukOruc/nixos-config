{
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  inherit (osConfig.oruc.machine) features;
  defaultHost = if features.boxBrowser then "local" else "devbox";
  appDefaultHost = if features.grokBotBox then "local" else "devbox";
  boxBrowserVncPort = 5920;
  accounts = import ../../nixosModules/grok-bot-accounts.nix;
  accountPorts = lib.concatStrings (
    lib.mapAttrsToList (account: ports: ''
      ${account}) port=${toString ports.vncPort} ;;
    '') accounts
  );

  boxView = pkgs.writeShellApplication {
    name = "box-view";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.libnotify
      pkgs.openssh
      pkgs.tigervnc
    ];
    text = ''
      usage() {
        echo "usage: box-view [HOST] [--app ACCOUNT]" >&2
        echo "  Opens the box browser of HOST, or with --app the Grok Bot app signed in to ACCOUNT (${lib.concatStringsSep ", " (lib.attrNames accounts)})." >&2
        exit 2
      }
      host=
      app=
      while (($#)); do
        case $1 in
          --app)
            app=''${2-}
            [[ -n $app ]] || usage
            shift 2
            ;;
          --app=*)
            app=''${1#*=}
            [[ -n $app ]] || usage
            shift
            ;;
          -*) usage ;;
          *)
            [[ -z $host ]] || usage
            host=$1
            shift
            ;;
        esac
      done
      port=${toString boxBrowserVncPort}
      title="Box browser"
      if [[ -n $app ]]; then
        title="Grok Bot ($app)"
        host=''${host:-${appDefaultHost}}
        case $app in
          ${accountPorts}
          *)
            echo "box-view: $app is not a Grok Bot account." >&2
            usage
            ;;
        esac
      fi
      host=''${host:-${defaultHost}}
      [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] || {
        echo "box-view: $host is not a host name." >&2
        exit 2
      }
      display="127.0.0.1::$port"

      if [[ $host != local && $host != "$(uname -n)" ]]; then
        tunnel_dir=$(mktemp -d "''${XDG_RUNTIME_DIR:?}/box-view.XXXXXX")
        display=$tunnel_dir/vnc.sock
        ssh -N -o ExitOnForwardFailure=yes -o BatchMode=yes -o ConnectTimeout=10 \
          -L "$display:127.0.0.1:$port" -- "$host" 2> "$tunnel_dir/ssh.log" &
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
          notify-send --app-name=box-view --icon=dialog-error "$title" "The SSH tunnel to $host did not come up." || true
          exit 1
        fi
      fi

      rc=0
      vncviewer -Log '*:stderr:0' "$display" || rc=$?
      if ((rc != 0)); then
        echo "box-view: the viewer for $host exited with status $rc." >&2
        notify-send --app-name=box-view --icon=dialog-error "$title" "The viewer for $host exited with status $rc." || true
        exit "$rc"
      fi
    '';
  };
in
{
  home.packages = [ boxView ];

  xdg.desktopEntries = {
    box-view = {
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
  // lib.mapAttrs' (
    account: _:
    lib.nameValuePair "box-view-grok-bot-${account}" {
      name = "Grok Bot on ${if features.grokBotBox then "this host" else appDefaultHost}: ${account}";
      comment = "The agents' Grok Bot app that is signed in to the ${account} account";
      exec = "${lib.getExe boxView} --app ${account}";
      icon = "grok-bot";
      terminal = false;
      categories = [ "Network" ];
    }
  ) accounts;
}
