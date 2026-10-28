{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
{
  imports = [
    ../../home-manager/profiles/workstation.nix
    ../../home-manager/modules/desktop-sync.nix
    ../../home-manager/modules/heavy.nix
    ./easyeffects.nix
    ./hdr.nix
    ./hushmic.nix
    ./mpv.nix
    ./oled-care.nix
    ../../home-manager/modules/box-view.nix
    ../../home-manager/modules/sshfs-risoluto-dev-1.nix
    ../../home-manager/modules/warp-launchers.nix
  ];

  # This sets only these keys, because input.touchpads would also delete every
  # touchpad key it does not set, such as pointer speed. The group name is this
  # laptop's vendor, product and device name.
  programs.plasma.configFile.kcminputrc."Libinput/10248/537/ASUF1209:00 2808:0219 Touchpad" = {
    Enabled = true;
    TapToClick = osConfig.oruc.machine.touchpad.tapToClick;
    NaturalScroll = osConfig.oruc.machine.touchpad.naturalScroll;
  };

  programs.plasma.hotkeys.commands.aura-next = {
    comment = "Next keyboard light effect";
    command = "${lib.getExe' osConfig.services.asusd.package "asusctl"} aura effect --next-mode";
    key = "Launch (3)";
  };

  # Deskflow runs here as the client of nixos-desktop's server. A client on
  # Wayland types through the remote desktop portal, which Plasma has and niri
  # does not, so it starts at a Plasma login only. The portal reads the app ID
  # from the unit name (app-<ID>.service), and Plasma names the app in its
  # remote control notice by that ID. Any other unit name shows the notice as
  # "An unidentifiable application".
  systemd.user.services."app-org.deskflow.deskflow" = {
    Unit = {
      Description = "Deskflow client of nixos-desktop";
      After = [ "plasma-workspace.target" ];
      PartOf = [ "plasma-workspace.target" ];
      RefuseManualStart = true;
      RefuseManualStop = true;
    };
    Service = {
      ExecStart = lib.getExe pkgs.deskflow;
      Restart = "on-failure";
      RestartSec = 5;
      # Deskflow exits 5 when another instance runs, such as one started from
      # the menu. A restart would only raise that instance's window again.
      SuccessExitStatus = 5;
    };
    Install.WantedBy = [ "plasma-workspace.target" ];
  };

  home.activation.deskflowLogToFile =
    lib.hm.dag.entryBetween [ "reloadSystemd" ] [ "writeBoundary" ]
      ''
        run mkdir -p ${config.xdg.configHome}/Deskflow
        run ${lib.getExe pkgs.crudini} --ini-options=nospace --set \
          ${config.xdg.configHome}/Deskflow/Deskflow.conf log toFile true
      '';

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
    "applications:org.opengamingcollective.rog-control-center.desktop"
    "applications:slack.desktop"
    "applications:brave-ompifgpmddkgmclendfeacglnodjjndh-Default.desktop"
    "applications:brave-hnpfjngllnobngcgfapefoaidbinmjnm-Default.desktop"
    "applications:discord.desktop"
    "applications:org.telegram.desktop.desktop"
    "applications:spotify.desktop"
    "applications:md.obsidian.Obsidian.desktop"
  ];
}
