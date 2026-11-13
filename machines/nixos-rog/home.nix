{
  lib,
  osConfig,
  pkgs,
  ...
}:
{
  home.packages = [
    pkgs.awscli2
    pkgs.aws-signing-helper
  ];

  imports = [
    ./easyeffects.nix
    ./hdr.nix
    ./hushmic.nix
    ./inbox-browser-tests.nix
    ./mpv.nix
    ./oled-care.nix
  ];

  oruc.deskflow.role = "client";

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

  oruc.plasma.dockLaunchers = lib.mkAfter [
    "applications:org.opengamingcollective.rog-control-center.desktop"
  ];
}
