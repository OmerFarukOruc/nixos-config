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

  # The GBT M27UP can keep brightness below a DDC/CI write because of a menu
  # setting that only its Reset all clears. libddcutil's read-back then fails
  # (DDCRC_VERIFY) and powerdevil drops the slider.
  xdg.configFile."ddcutil/ddcutilrc".text = ''
    [libddcutil]
    options: --noverify
  '';
}
