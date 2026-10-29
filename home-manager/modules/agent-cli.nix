{
  agents,
  config,
  pkgs,
  ...
}:
{
  imports = [ ./worktree-sweep.nix ];

  home.packages = [
    agents.agent-browser
    agents.pi
    pkgs.mitmproxy
  ];

  programs.worktrunk = {
    enable = true;
    enableZshIntegration = true;
    claudeCodeIntegration.enable = false;
    settings = {
      worktree-path = "${config.home.homeDirectory}/Desktop/workspace/worktrees/{{ repo }}/{{ branch | sanitize }}";
      skip-shell-integration-prompt = true;
      skip-commit-generation-prompt = true;
      pre-start.direnv = "if [ -e .envrc ]; then direnv allow . && direnv exec . true; fi";
      pre-remove.devenv = "if [ -e devenv.nix ] && command -v devenv >/dev/null && devenv processes list >/dev/null 2>&1; then devenv down; fi";
    };
  };
}
