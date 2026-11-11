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
  ampInstall = pkgs.writeShellApplication {
    name = "amp-install";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gzip
      util-linux
    ];
    text = builtins.readFile ./amp-install.sh;
  };
  ampOrbDispatch = pkgs.writeShellApplication {
    name = "amp-orb-dispatch";
    runtimeInputs = [ pkgs.docker-client ];
    text = builtins.readFile ./amp-orb-dispatch.sh;
  };
  home = config.home.homeDirectory;
  failureMarker =
    name: hint:
    let
      failure = import ../../home-manager/modules/failure-marker.nix { inherit lib pkgs; } name hint;
    in
    {
      service = {
        StateDirectory = name;
        ExecStopPost = failure.execStopPost;
      };
      inherit (failure) initContent;
    };
  auditMarker = failureMarker "statuslantern-audit" "journalctl --user -u statuslantern-audit -n 40";
  nightlyMarker = failureMarker "statuslantern-nightly" "journalctl --user -u statuslantern-nightly -n 40; the night's folder is in ~/.local/state/statuslantern-nightly/runs";
  factoryRunMarker = failureMarker "statuslantern-factory-run" "journalctl --user -u statuslantern-factory-run -n 40; the run's folder is in ~/.local/state/statuslantern-factory/runs";
  triageMarker = failureMarker "statuslantern-factory-triage" "journalctl --user -u statuslantern-factory-triage -n 40; the day's start is reserved in ~/.local/state/statuslantern-factory/starts";
  factoryService =
    {
      description,
      script,
      service,
      unit ? { },
      install ? { },
    }:
    {
      Unit = {
        Description = description;
      }
      // unit;
      Service = {
        WorkingDirectory = "%h/Desktop/workspace/statuslantern";
        Environment = [
          "PATH=/run/wrappers/bin:/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"
        ];
        ExecStart = "${lib.getExe pkgs.devenv} shell -- ${script}";
      }
      // service;
      Install = install;
    };
  factoryResident = {
    service = {
      Restart = "always";
      RestartSec = 5;
    };
    install.WantedBy = [ "default.target" ];
  };
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
    ampOrbDispatch
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
        ExecStartPre = lib.getExe ampInstall;
        ExecStart = "${lib.getExe pkgs.zsh} -c 'PATH=%h/.amp/bin:$$PATH exec amp --no-tui --runner-id %H --discover-dirs=%h/Desktop/workspace --no-serve-cwd --remote-control-terminal --desktop'";
        WorkingDirectory = "${home}/Desktop/workspace";
        Restart = "always";
        RestartSec = 10;
      };
      Install.WantedBy = [ "default.target" ];
    };
    amp-orb-provider = {
      Unit = {
        Description = "Amp orb provider that runs Omer's orbs in rootless Docker (outbound connection only)";
        After = [
          "docker.service"
          "network-online.target"
        ];
        Wants = [
          "docker.service"
          "network-online.target"
        ];
        X-SwitchMethod = "keep-old";
      };
      Service = {
        ExecStartPre = lib.getExe ampInstall;
        ExecStart = "%h/.amp/bin/amp orb provider /etc/profiles/per-user/${config.home.username}/bin/amp-orb-dispatch";
        Environment = [
          "DOCKER_HOST=unix://%t/docker.sock"
          "PATH=%h/.amp/bin:/run/wrappers/bin:/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"
        ];
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
        Environment = [ "XAUTHORITY=%h/.Xauthority" ];
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
    Unit = {
      Description = "Start the daily Status Lantern telemetry audit agent";
      X-SwitchMethod = "keep-old";
    };
    Service = {
      Type = "oneshot";
      WorkingDirectory = "%h/Desktop/workspace/statuslantern";
      Environment = [
        "PATH=/etc/profiles/per-user/omer/bin:/run/current-system/sw/bin"
        "STATUSLANTERN_AUDIT_AGENT=claude"
      ];
      ExecStart = "${lib.getExe pkgs.devenv} shell -- audit-start";
      TimeoutStartSec = "15min";
    }
    // auditMarker.service;
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

  systemd.user.services.statuslantern-nightly = factoryService {
    description = "Run the nightly Status Lantern dependency, docs and inventory pull request";
    script = "nightly-start";
    service = {
      Type = "oneshot";
      TimeoutStartSec = "10h30min";
      TimeoutStopSec = "10min";
      StateDirectoryMode = "0700";
    }
    // nightlyMarker.service;
    unit.X-SwitchMethod = "keep-old";
  };
  systemd.user.timers.statuslantern-nightly = {
    Unit.Description = "Run the nightly Status Lantern pull request every day";
    Timer = {
      OnCalendar = "*-*-* 14:30:00 UTC";
      RandomizedDelaySec = "5m";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };

  systemd.user.services.statuslantern-factory-receive = factoryService (
    factoryResident
    // {
      description = "Receive Lamplighter's agent session webhooks for the Status Lantern factory";
      script = "factory-receive";
    }
  );
  systemd.user.services.statuslantern-factory-tunnel = factoryService (
    factoryResident
    // {
      description = "Carry factory.statuslantern.com to the factory receiver through a Cloudflare Tunnel";
      script = "factory-tunnel";
    }
  );
  systemd.user.services.statuslantern-factory-run = factoryService {
    description = "Run the oldest Status Lantern factory event";
    script = "factory-run";
    service = {
      Type = "oneshot";
      TimeoutStartSec = "6h30min";
    }
    // factoryRunMarker.service;
    unit = {
      StartLimitIntervalSec = 0;
      X-SwitchMethod = "keep-old";
    };
  };
  systemd.user.paths.statuslantern-factory-run = {
    Unit.Description = "Start the factory run while its inbox holds an event";
    Path = {
      DirectoryNotEmpty = "%h/.local/state/statuslantern-factory/inbox";
      MakeDirectory = true;
    };
    Install.WantedBy = [ "paths.target" ];
  };

  systemd.user.services.statuslantern-factory-triage = factoryService {
    description = "Start a factory run on the oldest open Status Lantern audit issue";
    script = "triage-start";
    unit.X-SwitchMethod = "keep-old";
    service = {
      Type = "oneshot";
      TimeoutStartSec = "15min";
    }
    // triageMarker.service;
  };
  programs.zsh.initContent = lib.concatMapStrings (m: m.initContent) [
    auditMarker
    nightlyMarker
    factoryRunMarker
    triageMarker
  ];
  systemd.user.timers.statuslantern-factory-triage = {
    Unit.Description = "Start the factory's triage run every morning, two hours after the audit";
    Timer = {
      OnCalendar = "*-*-* 08:00 Europe/Istanbul";
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
