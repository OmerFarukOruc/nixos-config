# The Claude accounts widget (org.oruc.claudeaccounts) for the Plasma top bar.
# It shows ~/.cache/claude-usage/usage.json, which the dotfiles checkout's
# desktop/bin/claude-usage writes, and its buttons run that checkout's
# claude-usage and claude-accounts. Installed with the panels, it loads before
# the checkout exists; Plasma drops a widget it cannot load from the panel.
{ runCommand }:
runCommand "claude-accounts-widget" { } ''
  mkdir -p $out/share/plasma/plasmoids
  cp -r ${./claude-accounts-widget} $out/share/plasma/plasmoids/org.oruc.claudeaccounts
''
