{
  claudeTools,
  lib,
  runCommandLocal,
}:
runCommandLocal "claude-accounts-widget"
  {
    meta = {
      description = "Claude Code account usage and login state in the Plasma panel";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
    };
  }
  ''
    mkdir -p $out/share/plasma/plasmoids
    dir=$out/share/plasma/plasmoids/org.oruc.claudeaccounts
    cp -r ${./claude-accounts-widget} $dir
    chmod -R u+w $dir
    substituteInPlace $dir/contents/ui/Logic.js --replace-fail @claudeTools@ ${claudeTools}
  ''
