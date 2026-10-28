{
  config,
  lib,
  pkgs,
  ...
}:
let
  deskflowLayout = pkgs.writeText "deskflow-server.conf" ''
    section: links
    	nixos-rog:
    		right = nixos-desktop
    	nixos-desktop:
    		left = nixos-rog
    end
  '';
in
{
  imports = [
    ../../home-manager/profiles/workstation.nix
    ../../home-manager/modules/desktop-sync.nix
    ../../home-manager/modules/heavy.nix
    ../../home-manager/modules/box-view.nix
    ../../home-manager/modules/sshfs-risoluto-dev-1.nix
    ../../home-manager/modules/warp-launchers.nix
  ];

  home.packages = [
    pkgs.awscli2
    pkgs.aws-signing-helper
  ];

  oruc.plasma.dockLaunchers = [
    "preferred://filemanager"
    "applications:io.missioncenter.MissionCenter.desktop"
    "preferred://browser"
    "applications:com.mitchellh.ghostty.desktop"
    "applications:SourceGit.desktop"
    "applications:code.desktop"
    "applications:chatgpt.desktop"
    "applications:com.anthropic.Claude.desktop"
    "applications:grok-bot.desktop"
    "applications:openchamber.desktop"
    "applications:cursor.desktop"
    "applications:slack.desktop"
    "applications:brave-ompifgpmddkgmclendfeacglnodjjndh-Default.desktop"
    "applications:brave-hnpfjngllnobngcgfapefoaidbinmjnm-Default.desktop"
    "applications:discord.desktop"
    "applications:org.telegram.desktop.desktop"
    "applications:spotify.desktop"
    "applications:md.obsidian.Obsidian.desktop"
  ];

  # Claude Desktop marks its window as demanding attention on every Alt+Tab,
  # which makes an auto-hide panel show itself. This KWin script clears the
  # flag on Claude's windows only.
  xdg.dataFile."kwin/scripts/noclaudeattention".source = ./kwin-scripts/noclaudeattention;
  programs.plasma.configFile.kwinrc.Plugins.noclaudeattentionEnabled = true;

  systemd.user.services."app-org.deskflow.deskflow" = {
    Unit = {
      Description = "Deskflow server";
      After = [ "plasma-workspace.target" ];
      PartOf = [ "plasma-workspace.target" ];
      RefuseManualStart = true;
      RefuseManualStop = true;
    };
    Service = {
      ExecStart = lib.getExe pkgs.deskflow;
      Restart = "on-failure";
      RestartSec = 5;
      SuccessExitStatus = 5;
    };
    Install.WantedBy = [ "plasma-workspace.target" ];
  };

  home.activation.deskflowServer = lib.hm.dag.entryBetween [ "reloadSystemd" ] [ "writeBoundary" ] ''
    conf=${config.xdg.configHome}/Deskflow/Deskflow.conf
    ini=(${lib.getExe pkgs.crudini} --ini-options=nospace --set "$conf")
    run mkdir -p ${config.xdg.configHome}/Deskflow
    run "''${ini[@]}" core coreMode 2
    run "''${ini[@]}" server externalConfig true
    run "''${ini[@]}" server externalConfigFile ${deskflowLayout}
    for computer in nixos-desktop nixos-rog; do
      run "''${ini[@]}" "computer_$computer" name "$computer"
    done
    run "''${ini[@]}" log toFile true
    run "''${ini[@]}" gui startCoreWithGui true
  '';
}
