# Home Manager layer of nixos-desktop: its own apps and units, on top of the
# workstation and personal profiles.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # nixos-rog sits left of this screen. Deskflow 1.27 skips a screens
  # section here; it reads the computers from Deskflow.conf, which the
  # activation below writes.
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
    ../../home-manager/modules/sshfs-risoluto-dev-1.nix
  ];

  # The AWS CLI and the Roles Anywhere credential helper, which reads its key
  # from the TPM.
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
    "applications:com.anthropic.Claude.desktop"
    "applications:discord.desktop"
    "applications:org.telegram.desktop.desktop"
    "applications:spotify.desktop"
    "applications:org.openrgb.OpenRGB.desktop"
    "applications:io.github.ilya_zlobintsev.LACT.desktop"
    "applications:org.deskflow.deskflow.desktop"
    "applications:systemsettings.desktop"
  ];

  # Claude Desktop marks its window as demanding attention on every Alt+Tab,
  # which makes an auto-hide panel show itself. This KWin script clears the
  # flag on Claude's windows only.
  xdg.dataFile."kwin/scripts/noclaudeattention".source = ./kwin-scripts/noclaudeattention;
  programs.plasma.configFile.kwinrc.Plugins.noclaudeattentionEnabled = true;

  # The Deskflow server; nixos-rog runs the client. Deskflow on Wayland reads
  # the keyboard and mouse through the input capture portal, so it starts at
  # a Plasma login. The unit name gives the portal the app ID, as on rog
  # (machines/nixos-rog/home.nix), and the same switch rules apply.
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
      # Deskflow exits 5 when another instance runs.
      SuccessExitStatus = 5;
    };
    Install.WantedBy = [ "plasma-workspace.target" ];
  };

  # Deskflow keeps its own settings in Deskflow.conf, so the switch sets only
  # these keys: server mode, the screen layout above, its computers, the log in
  # ~/deskflow.log, and a server that starts with the window.
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
