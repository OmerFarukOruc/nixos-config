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
  claudeTools = pkgs.callPackage ../../pkgs/claude-tools.nix { };
  herdrWebUi = pkgs.callPackage ../../pkgs/herdr-web-ui.nix { };
  openchamberWeb = pkgs.callPackage ../../pkgs/openchamber-web.nix { };
  stayGreen = pkgs.callPackage ../../pkgs/stay-green.nix { src = inputs.stay-green; };
  home = config.home.homeDirectory;
in
{
  imports = [
    ../../home-manager/modules/agent-cli.nix
    ../../home-manager/modules/claude-tools.nix
    ../../home-manager/modules/openrouter-free-guardrail.nix
    ../../home-manager/modules/playwright.nix
  ];

  home.packages = [
    agents.amp
    pkgs.aws-signing-helper
    pkgs.awscli2
    (pkgs.callPackage ../../pkgs/cf.nix { })
    pkgs.defuddle
    pkgs.devenv
    pkgs.glow
    (pkgs.callPackage ../../pkgs/impeccable.nix { })
    pkgs.openssl
    stayGreen
    pkgs.wrangler
  ];

  # Node from a project's mise.toml comes prebuilt and runs through nix-ld;
  # mise's default on NixOS compiles it, which fails.
  home.sessionVariables.MISE_NODE_COMPILE = "false";
  home.sessionVariables.PYTHONNOUSERSITE = "true";

  systemd.user.services.openchamber = {
    Unit = {
      Description = "OpenChamber web UI for OpenCode (loopback only)";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
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

  systemd.user.services.infisical-agent = {
    Unit = {
      Description = "Infisical Agent: keeps a token and the secret files under %t/infisical-agent current";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
      X-Restart-Triggers = [
        (builtins.hashString "sha256" osConfig.sops.templates."infisical-agent.yaml".content)
      ];
    };
    Service = {
      ExecStart = "${lib.getExe pkgs.infisical} agent --config ${
        osConfig.sops.templates."infisical-agent.yaml".path
      }";
      ExecStartPost = toString (
        pkgs.writeShellScript "infisical-agent-rendered" ''
          for _ in {1..60}; do
            [[ -s $RUNTIME_DIRECTORY/openrouter-guardrail.env ]] && exit 0
            ${pkgs.coreutils}/bin/sleep 1
          done
          echo "the agent wrote no openrouter-guardrail.env within 60 s" >&2
          exit 1
        ''
      );
      RuntimeDirectory = "infisical-agent";
      WorkingDirectory = "%t/infisical-agent";
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
      Restart = "on-failure";
      RestartSec = 30;
    };
    Install.WantedBy = [ "default.target" ];
  };

  systemd.user.services.openrouter-free-guardrail = {
    Unit = {
      Wants = [ "infisical-agent.service" ];
      After = [ "infisical-agent.service" ];
    };
    Service.EnvironmentFile = "-%t/infisical-agent/openrouter-guardrail.env";
  };

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
        "HERDR_WEB_APP_NAME=devbox"
        "HERDR_WEB_STATE_DIR=${home}/.local/state/herdr-web-ui"
        "HERDR_WEB_PASTE_DIR=${home}/.local/state/herdr-web-ui/paste"
      ];
      Restart = "always";
      RestartSec = 3;
    };
    Install.WantedBy = [ "default.target" ];
  };

  systemd.user.services = {
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
    cursor-worker = {
      Unit = {
        Description = "Cursor Cloud Agent worker for Omer's My Machines (outbound connection only)";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
        X-SwitchMethod = "keep-old";
      };
      Service = {
        ExecStart = "${lib.getExe pkgs.zsh} -c 'exec cursor-agent worker --computer-use --share-desktop --name %H --worker-dir %h/Desktop/workspace --idle-release-timeout 0 start'";
        WorkingDirectory = "${home}/Desktop/workspace";
        Restart = "always";
        RestartSec = 10;
      };
      Install.WantedBy = [ "default.target" ];
    };
  };

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
        TimeoutStartSec = "15min";
      };
      Install.WantedBy = [ "default.target" ];
    };
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

  systemd.user.services.claude-tools-limit-switch = {
    Unit.Description = "Move herdr Claude agents off accounts that hit a usage limit";
    Service = {
      Type = "oneshot";
      ExecStart = "${claudeTools}/bin/claude-tools limit-switch scan";
    };
  };
  systemd.user.timers.claude-tools-limit-switch = {
    Unit.Description = "Move herdr Claude agents off accounts that hit a usage limit, every minute";
    Timer = {
      OnCalendar = "*:*:00";
      AccuracySec = "10s";
      Persistent = false;
    };
    Install.WantedBy = [ "timers.target" ];
  };

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
      Persistent = false;
    };
    Install.WantedBy = [ "timers.target" ];
  };

  systemd.user.services.statuslantern-audit = {
    Unit.Description = "Start the daily Status Lantern telemetry audit agent";
    Service = {
      Type = "oneshot";
      WorkingDirectory = "%h/Desktop/workspace/statuslantern";
      Environment = [
        "PATH=/etc/profiles/per-user/omer/bin:/run/current-system/sw/bin"
        "STATUSLANTERN_AUDIT_AGENT=claude"
      ];
      ExecStart = "${lib.getExe pkgs.devenv} shell -- audit-start";
      TimeoutStartSec = "15min";
    };
  };
  systemd.user.timers.statuslantern-audit = {
    Unit.Description = "Run the Status Lantern telemetry audit every morning";
    Timer = {
      OnCalendar = "*-*-* 06:00 Europe/Istanbul";
      RandomizedDelaySec = "5m";
      Persistent = true;
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
