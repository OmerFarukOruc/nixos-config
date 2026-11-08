{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  claudeTools = pkgs.callPackage ../../pkgs/claude-tools.nix { };
  accounts = osConfig.sops.secrets.claude-tools-accounts.path;
in
{
  xdg.configFile = {
    "claude-tools/accounts.json".source = config.lib.file.mkOutOfStoreSymlink accounts;
    "claude-tools/account-prefs.json".text = builtins.toJSON { leftArrowOpensAgents = false; };
  };

  home.activation.claudeToolsPrefs = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    run env PATH="${
      lib.makeBinPath [ pkgs.util-linux ]
    }:$PATH" ${claudeTools}/bin/claude-tools accounts prefs ||
      warnEcho "claude-tools accounts prefs failed; the lines above name the account file or lock that stopped it"
  '';

  home.packages = [
    claudeTools
    pkgs.gum
    pkgs.jq
    pkgs.openssh
    (pkgs.callPackage ../../pkgs/agent-python.nix { })
    pkgs.tmux
  ];

  programs.zsh.initContent = lib.mkOrder 1500 ''
    . ${claudeTools}/share/claude-tools/claude-tools.sh
  '';

  oruc.plasma.claudeAccountsWidget = true;

  programs.claude-code.settings.hooks.StopFailure = [
    {
      matcher = "rate_limit";
      hooks = [
        {
          type = "command";
          command = "${claudeTools}/libexec/claude-tools/rotate-on-limit";
        }
      ];
    }
  ];

  systemd.user.services.claude-tools-usage = {
    Unit = {
      Description = "Read the usage limits and login state of every Claude Code account";
      ConditionPathExists = accounts;
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${claudeTools}/bin/claude-tools usage --quiet";
      Environment = [
        "PATH=${config.home.homeDirectory}/.local/bin:/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"
      ];
      TimeoutStartSec = "15min";
    };
  };
  systemd.user.timers.claude-tools-usage = {
    Unit.Description = "Read Claude Code account usage every 10 minutes";
    Timer = {
      OnCalendar = "*:0/10";
      RandomizedDelaySec = "30s";
      OnStartupSec = "1min";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
