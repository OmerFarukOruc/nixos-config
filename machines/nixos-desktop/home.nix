{ pkgs, ... }:
{
  oruc.deskflow.role = "server";

  home.packages = [
    pkgs.awscli2
    pkgs.aws-signing-helper
  ];

  # Claude Desktop marks its window as demanding attention on every Alt+Tab,
  # which makes an auto-hide panel show itself. This KWin script clears the
  # flag on Claude's windows only.
  xdg.dataFile."kwin/scripts/noclaudeattention".source = ./kwin-scripts/noclaudeattention;
  programs.plasma.configFile.kwinrc.Plugins.noclaudeattentionEnabled = true;
}
