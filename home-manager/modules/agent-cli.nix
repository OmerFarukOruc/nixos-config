{
  agents,
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [ ./worktree-sweep.nix ];

  oruc.piTheme = true;

  programs.zsh.envExtra = "export CLAUDE_CODE_WARN_MEMORY_FREE_GIB=4";

  home.packages = [
    agents.agent-browser
    agents.pi
    (pkgs.callPackage ../../pkgs/linctl.nix { })
    pkgs.mitmproxy
  ];

  programs.worktrunk = {
    enable = true;
    enableZshIntegration = true;
    claudeCodeIntegration = {
      enable = true;
      statusLine = false;
    };
    settings = {
      worktree-path = "${config.home.homeDirectory}/Desktop/workspace/worktrees/{{ repo }}/{{ branch | sanitize }}";
      skip-shell-integration-prompt = true;
      skip-commit-generation-prompt = true;
      pre-start.direnv = "{% if pr_number %}echo 'direnv skipped in this pr:{{ pr_number }} worktree: read its .envrc and devenv.nix, then run direnv allow'{% else %}if [ -e .envrc ]; then direnv allow . && direnv exec . true; fi{% endif %}";
      pre-remove.devenv = "if [ -e devenv.nix ] && command -v devenv >/dev/null && devenv processes list >/dev/null 2>&1; then devenv down; fi";
    };
  };

  programs.claude-code.settings.hooks.WorktreeRemove = lib.mkForce [
    {
      hooks = [
        {
          type = "command";
          command = "bash -c 'p=$(${lib.getExe pkgs.jq} -er .worktree_path) || exit 1; [ -e \"$p/.git\" ] || exit 0; ${lib.getExe config.programs.worktrunk.package} -C \"$p\" remove --foreground --force \"$p\"'";
        }
      ];
    }
  ];
}
