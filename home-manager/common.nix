{ ... }:
{
  imports = [
    ./modules/appearance.nix
    ./modules/applications.nix
    ./modules/claude-code-theme.nix
    ./modules/dev-ca.nix
    ./modules/editor
    ./modules/git.nix
    ./modules/herdr.nix
    ./modules/idle.nix
    ./modules/launchers
    ./modules/markdown-viewer
    ./modules/niri-session.nix
    ./modules/oruc-shell.nix
    ./modules/plasma-apps.nix
    ./modules/plasma-looks
    ./modules/plasma-manager.nix
    ./modules/plasma-panels.nix
    ./modules/session-scope.nix
    ./modules/shell.nix
    ./modules/shells
    ./modules/theme-pack.nix
    ./modules/theme.nix
    ./modules/variants.nix
    ./modules/vscode.nix
  ];

  xdg.userDirs = {
    enable = true;
    createDirectories = false;
    publicShare = "/var/empty";
    templates = "/var/empty";
    projects = null;
  };
  programs.home-manager.enable = true;
}
