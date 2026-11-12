{
  config,
  lib,
  pkgs,
  ...
}:
let
  user = "sl-factory";
  home = config.users.users.${user}.home;
  accounts = [
    "own-team"
    "work1"
    "work1-team"
    "work2"
    "work2-team"
  ];
  upstreamSkills = config.home-manager.users.${config.oruc.machine.user}.oruc.agents.upstreamSkills;
  files = pkgs.linkFarm "sl-factory-claude-files" [
    {
      name = "agents/code-reviewer.md";
      path = ../../agents/claude/agents/code-reviewer.md;
    }
    {
      name = "agents/comment-sicko.md";
      path = ../../agents/claude/agents/comment-sicko.md;
    }
    {
      name = "skills/ub-mode";
      path = "${upstreamSkills}/ub-mode";
    }
    {
      name = "skills/thermo-nuclear-code-quality-review";
      path = ../../agents/skills/thermo-nuclear-code-quality-review;
    }
    {
      name = "shared/core.md";
      path = ../../agents/shared/core.md;
    }
    {
      name = "shared/testing-discipline.md";
      path = ../../agents/shared/testing-discipline.md;
    }
    {
      name = "shared/engineering.md";
      path = ../../agents/shared/engineering.md;
    }
    {
      name = "shared/reviews.md";
      path = ../../agents/shared/reviews.md;
    }
  ];
  agentTools = pkgs.callPackage ../../pkgs/agent-tools.nix { };
  reviewerTools = pkgs.linkFarm "sl-factory-reviewer-tools" (
    map
      (tool: {
        name = "bin/${tool}";
        path = "${agentTools}/bin/${tool}";
      })
      [
        "codex-ask"
        "wait-exit"
        "sandbox-run"
        "dryer"
      ]
  );
  link = path: target: "L+ ${path} - - - - ${target}";
  claudeTools = pkgs.callPackage ../../pkgs/claude-tools.nix { };
  toolsData = "${home}/.config/claude-tools";
  accountsFile = config.sops.secrets.claude-tools-accounts.path;
  writeAccounts = pkgs.writeShellScript "sl-factory-claude-tools-accounts" ''
    set -euo pipefail
    umask 077
    mkdir -p ${toolsData}
    ${pkgs.jq}/bin/jq 'del(.remote_hosts?)' "$CREDENTIALS_DIRECTORY/accounts.json" >${toolsData}/accounts.json.new
    mv ${toolsData}/accounts.json.new ${toolsData}/accounts.json
  '';
  configDirs = [ "${home}/.claude" ] ++ map (name: "${home}/.claude-accounts/${name}") accounts;
in
{
  users.users.${user}.packages = [ reviewerTools ];

  systemd.tmpfiles.rules =
    map (dir: "d ${dir} 0755 ${user} ${user} -") ([ "${home}/.claude-accounts" ] ++ configDirs)
    ++ lib.concatMap (dir: [
      (link "${dir}/agents" "${files}/agents")
      (link "${dir}/skills" "${files}/skills")
    ]) configDirs
    ++ [ (link "${home}/.claude/shared" "${files}/shared") ]
    ++ lib.concatMap (name: [
      (link "${home}/.claude-${name}" ".claude-accounts/${name}")
      "f ${home}/.claude-accounts/${name}/.claude-profile 0644 ${user} ${user} -"
    ]) accounts;

  systemd.services.claude-tools-usage-factory = {
    description = "Read the usage limits and login state of the Claude Code accounts of ${user}";
    unitConfig.ConditionPathExists = accountsFile;
    path = config.users.users.${user}.packages ++ [ pkgs.util-linux ];
    serviceConfig = {
      Type = "oneshot";
      User = user;
      LoadCredential = "accounts.json:${accountsFile}";
      ExecStartPre = "${writeAccounts}";
      ExecStart = "${claudeTools}/bin/claude-tools usage --quiet";
      TimeoutStartSec = "15min";
    };
  };

  systemd.timers.claude-tools-usage-factory = {
    description = "Read Claude Code account usage of ${user} every 10 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/10";
      RandomizedDelaySec = "30s";
      OnStartupSec = "1min";
    };
  };
}
