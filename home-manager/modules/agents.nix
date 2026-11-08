{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  cfg = config.oruc.agents;
  live = path: {
    source = config.lib.file.mkOutOfStoreSymlink "${cfg.checkout}/agents/${path}";
    force = true;
  };
  infisicalIds = osConfig.sops.secrets.agents-infisical-ids.path;
  pull = pkgs.writeShellApplication {
    name = "agents-pull";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.git
    ];
    text = builtins.readFile ./agents-pull.sh;
  };
  scheduledUnit = import ./scheduled-unit.nix { inherit config lib pkgs; };
in
{
  imports = [ ./agent-skills ];

  options.oruc.agents.checkout = lib.mkOption {
    type = lib.types.str;
    default = "${config.home.homeDirectory}/Desktop/workspace/nixos-config";
    description = "The nixos-config main checkout whose agents/ folder the agent CLIs read live (agents/README.md).";
  };

  config = lib.mkMerge [
    {
      home.packages = [
        pull
        (pkgs.callPackage ../../pkgs/agent-tools.nix { })
        pkgs.bubblewrap
      ];
    }
    {
      home.file =
        lib.mapAttrs' (name: _: lib.nameValuePair ".codex/agents/${name}" (live "codex/agents/${name}")) (
          builtins.readDir ../../agents/codex/agents
        )
        // {
          ".claude/CLAUDE.md" = live "claude/CLAUDE.md";
          ".claude/rules" = live "claude/rules";
          ".claude/shared" = live "shared";
          ".claude/reference" = live "reference";
          ".claude/infisical.md" = live "infisical.md";
          ".claude/hooks" = live "claude/hooks";
          ".claude/statusline.sh" = live "claude/statusline.sh";
          ".claude/agents" = live "claude/agents";
          ".codex/AGENTS.md" = {
            text =
              builtins.readFile ../../agents/shared/core.md
              + "\n"
              + builtins.readFile ../../agents/codex/codex.md;
            force = true;
          };
        };
      programs.claude-code = {
        mutableSettings = true;
        settings = lib.mkMerge [
          (lib.importJSON ../../agents/claude/settings.json)
          {
            env = {
              CLAUDE_ENV_FILE = "${config.home.homeDirectory}/.claude/hooks/bash-env.sh";
              CLAUDE_CODE_PLUGIN_DIRS = "${cfg.checkout}/agents/claude/mods/paste-card";
            };
          }
        ];
      };
      home.activation.agentsPull = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${lib.getExe' pkgs.coreutils "timeout"} 2m ${lib.getExe pull} ${lib.escapeShellArg cfg.checkout} \
          || warnEcho "agents-pull failed, so links under ~/.claude can point at files the checkout lacks until a run succeeds"
      '';
      programs.zsh.envExtra = ''
        if [[ -r ${infisicalIds} ]]; then
          source ${infisicalIds}
        fi
      '';
    }
    (scheduledUnit {
      name = "agents-pull";
      description = "Pull nixos-config main into the checkout that agents/ is read from";
      timerDescription = "Hourly pull of the nixos-config checkout";
      execStart = "${lib.getExe pull} ${lib.escapeShellArg cfg.checkout}";
      timeout = "10min";
      hint = "see journalctl --user -t agents-pull";
      onCalendar = "hourly";
      randomizedDelay = "10min";
    })
  ];
}
