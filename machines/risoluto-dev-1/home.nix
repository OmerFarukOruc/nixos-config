# Home Manager layer of risoluto-dev-1, on top of the layer that every host
# gets (home-manager/common.nix): the hourly sync that links Omer's agent config
# from the dotfiles checkout. Once the host runs NixOS, desktop-sync.sh leaves
# the shell and the tools to Home Manager, as on the workstations. The agents'
# Playwright runs the nixpkgs browsers, as on the desktops.
{
  agents,
  config,
  inputs,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  herdrWebUi = pkgs.callPackage ../../pkgs/herdr-web-ui.nix { };
  openchamberWeb = pkgs.callPackage ../../pkgs/openchamber-web.nix { };
  stayGreen = pkgs.callPackage ../../pkgs/stay-green.nix { src = inputs.stay-green; };
  home = config.home.homeDirectory;
in
{
  imports = [
    ../../home-manager/modules/agent-cli.nix
    ../../home-manager/modules/desktop-sync.nix
    ../../home-manager/modules/playwright.nix
  ];

  # The CLIs that only the agents on the box call. Project shells bring the
  # runtimes (Node, Bun, Go and the rest), as on the workstations.
  home.packages = [
    agents.amp
    pkgs.aws-signing-helper
    pkgs.awscli2
    (pkgs.callPackage ../../pkgs/cf.nix { })
    pkgs.defuddle
    pkgs.glow
    (pkgs.callPackage ../../pkgs/impeccable.nix { })
    stayGreen
    pkgs.wrangler
  ];

  # Node from a project's mise.toml comes prebuilt and runs through nix-ld;
  # mise's default on NixOS compiles it, which fails.
  home.sessionVariables.MISE_NODE_COMPILE = "false";

  # OpenChamber on loopback; tailnet-web.nix serves it as a tailnet name. It
  # shares ~/.config/opencode and the projects with Omer's shell and starts
  # OpenCode itself, which reads the server password.
  systemd.user.services.openchamber = {
    Unit = {
      Description = "OpenChamber web UI for OpenCode (loopback only)";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
      # A deploy leaves the running OpenChamber and the agents it started
      # alone; the new version starts at the next restart or boot.
      X-SwitchMethod = "keep-old";
    };
    Service = {
      EnvironmentFile = osConfig.sops.templates."openchamber.env".path;
      # OpenChamber's own OpenCode update installs to ~/.opencode/bin.
      ExecStart = "${lib.getExe pkgs.zsh} -c 'PATH=$HOME/.opencode/bin:$PATH exec ${lib.getExe openchamberWeb} --port 3000 --host 127.0.0.1 --foreground'";
      WorkingDirectory = "${home}/Desktop/workspace";
      Restart = "on-failure";
      RestartSec = 3;
    };
    Install.WantedBy = [ "default.target" ];
  };

  # herdr's web UI for the default session on loopback; tailnet-web.nix serves
  # it as a tailnet name. HERDR_WEB_TOKEN gates every request. The token
  # changes only with a deploy, and the unit reads it at start, so restart the
  # unit after the token changes.
  systemd.user.services.herdr-web-ui = {
    Unit = {
      Description = "herdr web UI for the default session (loopback only)";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      ExecStart = toString (
        pkgs.writeShellScript "herdr-web-ui-start" ''
          HERDR_WEB_TOKEN=$(<${osConfig.sops.secrets.herdr-web-token.path})
          [[ -n $HERDR_WEB_TOKEN ]] || { echo "the herdr web token is empty" >&2; exit 1; }
          export HERDR_WEB_TOKEN
          exec ${lib.getExe herdrWebUi}
        ''
      );
      Environment = [
        "HOST=127.0.0.1"
        "PORT=7317"
        "HERDR_SOCKET=${home}/.config/herdr/herdr.sock"
        "HERDR_WEB_TELEMETRY=0"
        "HERDR_WEB_AUTO_UPDATE=0"
        "HERDR_WEB_APP_NAME=risoluto-dev-1"
        "HERDR_WEB_STATE_DIR=${home}/.local/state/herdr-web-ui"
        "HERDR_WEB_PASTE_DIR=${home}/.local/state/herdr-web-ui/paste"
      ];
      Restart = "always";
      RestartSec = 3;
    };
    Install.WantedBy = [ "default.target" ];
  };

  # The agent services of Omer's own logins. Each starts `zsh -c`, so the work
  # it runs gets the PATH of Omer's non-interactive shell. A deploy leaves the
  # running ones alone (keep-old), so it ends no agent's work.
  systemd.user.services = {
    # herdr's default session, where Omer's own agents run, at boot and after
    # a crash. claude-limit-switch.timer starts it when no server runs. The
    # default KillMode ends the panes with the server, so no Claude outlives it
    # and runs twice after a restore.
    herdr-default = {
      Unit = {
        Description = "herdr default session, where Omer's own agents run";
        X-SwitchMethod = "keep-old";
      };
      Service = {
        UMask = "0022";
        # Panes start $SHELL, and the user manager sets it to bash.
        Environment = [ "SHELL=${lib.getExe pkgs.zsh}" ];
        WorkingDirectory = home;
        ExecStart = "${lib.getExe pkgs.zsh} -c 'exec herdr server'";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = [ "default.target" ];
    };
    # The Amp runner for threads Omer starts at ampcode.com, named after the
    # host. --discover-dirs serves every git checkout up to two levels under
    # ~/Desktop/workspace, including later clones.
    amp-runner = {
      Unit = {
        Description = "Amp runner for Omer's threads (outbound connection only)";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
        X-SwitchMethod = "keep-old";
      };
      Service = {
        ExecStart = "${lib.getExe pkgs.zsh} -c 'exec amp --no-tui --runner-id %H --discover-dirs=%h/Desktop/workspace --no-serve-cwd --remote-control-terminal --desktop'";
        WorkingDirectory = "${home}/Desktop/workspace";
        Restart = "always";
        RestartSec = 10;
      };
      Install.WantedBy = [ "default.target" ];
    };
    # The Cursor Cloud Agent worker under Omer's My Machines, named after the
    # host, with computer use on its own XFCE desktop. Each --worker-dir must
    # be a checkout with a GitHub remote. cursor-agent, because the name agent
    # is Grok's launcher here.
    cursor-worker = {
      Unit = {
        Description = "Cursor Cloud Agent worker for Omer's My Machines (outbound connection only)";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
        X-SwitchMethod = "keep-old";
      };
      Service = {
        ExecStart = "${lib.getExe pkgs.zsh} -c 'exec cursor-agent worker --computer-use --share-desktop --name %H --worker-dir %h/Desktop/workspace/dotfiles --idle-release-timeout 0 start'";
        WorkingDirectory = "${home}/Desktop/workspace/dotfiles";
        Restart = "always";
        RestartSec = 10;
      };
      Install.WantedBy = [ "default.target" ];
    };
  };

  # CLIProxyAPI, which serves the Claude, Codex, Gemini and Grok CLI logins as
  # one OpenAI-compatible API, on rootless Podman through the docker compose
  # CLI (cliproxy/compose.yml). The unit owns the stack, so no container starts
  # before its config exists. docs/risoluto-dev-1.md describes the share node.
  systemd.user.services.cliproxy =
    let
      up = "${./cliproxy}/cliproxy-up.sh";
    in
    {
      Unit = {
        Description = "CLIProxyAPI (loopback; tailnet-exposed via cliproxy-share)";
        After = [
          "network-online.target"
          "podman.socket"
        ];
        Wants = [ "network-online.target" ];
        Requires = [ "podman.socket" ];
      };
      Service = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = up;
        ExecReload = "${up} update";
        ExecStop = "${up} stop";
        Environment = [
          "PATH=${
            lib.makeBinPath [
              pkgs.coreutils
              pkgs.curl
              pkgs.gnugrep
              pkgs.jq
            ]
          }:/run/current-system/sw/bin"
          "CLIPROXY_RENDERED_CONFIG=${osConfig.sops.templates."cliproxy-config.yaml".path}"
          "CLIPROXY_DNS_TOKEN_FILE=${osConfig.sops.secrets.cliproxy-cloudflare-dns-token.path}"
        ];
        EnvironmentFile = osConfig.sops.templates."cliproxy.env".path;
        Restart = "on-failure";
        RestartSec = 5;
        # A first start builds the tls-proxy image.
        TimeoutStartSec = "15min";
      };
      Install.WantedBy = [ "default.target" ];
    };
  # Pulls new cliproxy and Tailscale images daily and recreates the containers
  # whose image changed. It fails when cliproxy.service is not active.
  systemd.user.services.cliproxy-update = {
    Unit = {
      Description = "CLIProxyAPI image update";
      After = [ "cliproxy.service" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl --user reload cliproxy.service";
    };
  };
  systemd.user.timers.cliproxy-update = {
    Unit.Description = "Daily CLIProxyAPI image update";
    Timer = {
      OnCalendar = "*-*-* 04:30 Europe/Istanbul";
      Persistent = true;
      RandomizedDelaySec = "15m";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # Every minute, claude-limit-switch (pkgs/claude-tools) starts herdr's
  # default session through herdr-default.service when no server runs, starts
  # the recorded Claude agents again after a server restart, and moves each
  # named agent whose screen ends in a usage limit message to another account.
  # A failed run means one agent could not move; the log names it and the
  # reason: journalctl --user -u claude-limit-switch.service and
  # ~/.local/state/claude-limit-switch/events.log.
  systemd.user.services.claude-limit-switch = {
    Unit.Description = "Move herdr Claude agents off accounts that hit a usage limit";
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.callPackage ../../pkgs/claude-tools.nix { }}/bin/claude-limit-switch scan";
    };
  };
  systemd.user.timers.claude-limit-switch = {
    Unit.Description = "Move herdr Claude agents off accounts that hit a usage limit, every minute";
    Timer = {
      OnCalendar = "*:*:00";
      AccuracySec = "10s";
      # A run missed while the box was down is of no use later.
      Persistent = false;
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # Keeps Omer's Teams status Available in working hours, with the sign-in in
  # ~/.local/state/stay-green. A failed run means the sign-in expired or was
  # revoked; sign in again from a workstation with
  # `stay-green login risoluto-dev-1`. The timer starts a run every 4 minutes
  # around the clock, and a run outside the schedule does nothing.
  systemd.user.services.stay-green = {
    Unit.Description = "Mark Omer's Teams status Available";
    Service = {
      Type = "oneshot";
      Environment = [
        # systemd splits an unquoted value at the space.
        "\"STAY_GREEN_SCHEDULE=Mon-Fri 09:00-18:00\""
        "STAY_GREEN_TIME_ZONE=Europe/Istanbul"
      ];
      ExecStart = "${lib.getExe stayGreen} run";
      # A stuck run would hold back the next ones.
      TimeoutStartSec = "2min";
      NoNewPrivileges = true;
      MemoryMax = "64M";
    };
  };
  systemd.user.timers.stay-green = {
    Unit.Description = "Keep Omer's Teams status Available in working hours";
    Timer = {
      OnCalendar = "*-*-* *:00/4:00";
      AccuracySec = "10s";
      # A run missed while the box was down is of no use later.
      Persistent = false;
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # /etc/zshenv replaces a unit's PATH, so every zsh, interactive or not, gets
  # the CLIs that installers put in the home: OpenCode's own update in
  # ~/.opencode/bin, and ~/.local/bin.
  home.sessionPath = [
    "$HOME/.local/bin"
    "$HOME/.opencode/bin"
  ];
}
