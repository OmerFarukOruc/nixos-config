{ ... }:
{
  imports = [
    ./modules/appearance.nix
    ./modules/applications.nix
    ./modules/editor
    ./modules/git.nix
    ./modules/htop.nix
    ./modules/idle.nix
    ./modules/launchers
    ./modules/markdown-viewer
    ./modules/niri-session.nix
    ./modules/oruc-shell.nix
    ./modules/plasma-manager.nix
    ./modules/plasma-panels.nix
    ./modules/session-scope.nix
    ./modules/shell.nix
    ./modules/shells
    ./modules/theme.nix
    ./modules/vscode.nix
  ];

  # Nothing uses Public or Templates, so they point at /var/empty, Projects is
  # left unset, and no folder is created; the other folders keep their defaults.
  xdg.userDirs = {
    enable = true;
    createDirectories = false;
    publicShare = "/var/empty";
    templates = "/var/empty";
    projects = null;
  };
  programs.home-manager.enable = true;
}
