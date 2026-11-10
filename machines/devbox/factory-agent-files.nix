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
    ++ [ (link "${home}/.claude/shared" "${files}/shared") ];
}
