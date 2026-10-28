# A signed-in, headful browser that coding agents share (features.boxBrowser).
# Xvnc is the display, localhost only and with no password, and Omer signs in to
# sites through a VNC viewer behind an SSH tunnel (box-view, in
# home-manager/modules/box-view.nix). Chromium runs on that display with a
# persistent profile and a DevTools port on localhost, and agent-browser drives
# it through the box-browser wrapper, one session per agent
# (docs/box-browser.md).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  displayNumber = 20;
  display = ":${toString displayNumber}";
  # Xvnc serves display :N on port 5900 + N; the number is spelled out because
  # box-view tunnels to this port.
  vncPort = 5920;
  cdpPort = 9344;

  # Xvnc sends no readiness signal, so the browser waits for its socket. A
  # Chromium that died hard leaves Singleton* files, and a reused process id
  # makes the next start refuse the profile as in use.
  browserPrepare = pkgs.writeShellApplication {
    name = "box-browser-prepare";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      profile="$HOME/.local/share/box-browser/profile"
      mkdir -p "$profile"
      rm -f "$profile/SingletonLock" "$profile/SingletonCookie" "$profile/SingletonSocket"
      for _ in {1..30}; do
        [[ -S /tmp/.X11-unix/X${toString displayNumber} ]] && exit 0
        sleep 1
      done
      echo "The X socket of display ${display} did not appear." >&2
      exit 1
    '';
  };

  # agent-browser comes from PATH: Home Manager installs it for the agents'
  # user (home-manager/modules/agent-cli.nix).
  boxBrowser = pkgs.writeShellApplication {
    name = "box-browser";
    runtimeInputs = [
      pkgs.curl
      pkgs.systemd
    ];
    text = ''
      status() {
        local failed=0 unit
        for unit in box-display box-browser; do
          if systemctl --user is-active --quiet "$unit.service"; then
            echo "$unit: active"
          else
            echo "$unit: not active" >&2
            failed=1
          fi
        done
        if curl --silent --fail --max-time 5 --output /dev/null http://127.0.0.1:${toString cdpPort}/json/version; then
          echo "CDP: answers on 127.0.0.1:${toString cdpPort}"
        else
          echo "CDP: no answer on 127.0.0.1:${toString cdpPort}" >&2
          failed=1
        fi
        return "$failed"
      }

      if [[ ''${1:-} == status ]]; then
        status
        exit
      fi

      has_session=false
      for arg in "$@"; do
        case $arg in
          --session | --session=*) has_session=true ;;
        esac
      done
      if [[ $has_session == false && -z ''${AGENT_BROWSER_SESSION:-} ]]; then
        if [[ -z ''${CLAUDE_CODE_SESSION_ID:-} ]]; then
          echo "box-browser: no session name. Pass --session NAME or set AGENT_BROWSER_SESSION; a Claude Code session names itself." >&2
          exit 2
        fi
        export AGENT_BROWSER_SESSION=$CLAUDE_CODE_SESSION_ID
      fi
      export AGENT_BROWSER_CDP=${toString cdpPort}
      export AGENT_BROWSER_PIN_TAB=1
      exec agent-browser "$@"
    '';
  };
in
{
  config = lib.mkIf config.oruc.machine.features.boxBrowser {
    # The units run with no login session.
    users.users.oruc.linger = true;

    # A server has no fonts, and Chromium draws no text without one.
    fonts.enableDefaultPackages = lib.mkDefault true;

    environment.systemPackages = [ boxBrowser ];

    systemd.user.services.box-display = {
      description = "Box browser display: Xvnc ${display}, localhost only, no password";
      wantedBy = [ "default.target" ];
      # Every user manager loads these units, and root's starts when a deploy
      # logs in as root. Its Xvnc found oruc's on the same display and failed
      # in a loop, which the deploy's session check took for a broken switch.
      unitConfig = {
        ConditionUser = "oruc";
        StartLimitIntervalSec = 0;
      };
      serviceConfig = {
        ExecStart = lib.concatStringsSep " " [
          (lib.getExe' pkgs.tigervnc "Xvnc")
          display
          "-localhost"
          "-rfbport ${toString vncPort}"
          "-nolisten tcp"
          "-SecurityTypes None"
          # The viewer's window title.
          "-desktop box-browser"
          "-geometry 1920x1080"
          "-depth 24"
          "-AlwaysShared"
        ];
        Restart = "always";
        RestartSec = 2;
      };
    };

    # partOf makes a restart of the display restart the browser, whose window
    # lives on it.
    systemd.user.services.box-browser = {
      description = "Box browser: Chromium on ${display}, DevTools on 127.0.0.1:${toString cdpPort}";
      requires = [ "box-display.service" ];
      after = [ "box-display.service" ];
      partOf = [ "box-display.service" ];
      wantedBy = [ "default.target" ];
      environment.DISPLAY = display;
      unitConfig = {
        ConditionUser = "oruc";
        StartLimitIntervalSec = 0;
      };
      serviceConfig = {
        ExecStartPre = lib.getExe browserPrepare;
        ExecStart = lib.concatStringsSep " " [
          (lib.getExe pkgs.chromium)
          "--user-data-dir=%h/.local/share/box-browser/profile"
          "--remote-debugging-address=127.0.0.1"
          "--remote-debugging-port=${toString cdpPort}"
          "--ozone-platform=x11"
          # Without a keyring, Chromium would ask for one at the first cookie.
          "--password-store=basic"
          "--no-first-run"
          "--no-default-browser-check"
          "--window-position=0,0"
          "--window-size=1920,1080"
        ];
        Restart = "always";
        RestartSec = 2;
      };
    };
  };
}
