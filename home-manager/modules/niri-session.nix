{
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  isNiri = sessions.hasDesktop osConfig.oruc.machine "niri";
  # Brave uses KWallet in every session of such a machine; see applications.nix.
  needsKwallet = isNiri && sessions.hasDesktop osConfig.oruc.machine "plasma";
in
{
  services.gnome-keyring = lib.mkIf isNiri {
    enable = true;
    components = [
      "pkcs11"
      "secrets"
    ];
  };

  # SDDM's PAM stack holds the login password for KWallet, and Plasma hands it
  # over with its own unit. This unit does the same at a niri login, so the
  # wallet opens without asking for the password.
  systemd.user.services.kwallet-pam = lib.mkIf needsKwallet {
    Unit.Description = "Unlock KWallet with the login password";
    Service = {
      ExecStart = "${pkgs.kdePackages.kwallet-pam}/libexec/pam_kwallet_init";
      Slice = "background.slice";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  services.blueman-applet.enable = isNiri;
  oruc.sessionServices = lib.mkMerge [
    (lib.mkIf isNiri {
      gnome-keyring = "niri";
      blueman-applet = "niri";
    })
    (lib.mkIf needsKwallet { kwallet-pam = "niri"; })
  ];
  # The applet's KillSwitch plugin soft-blocks the Dell Bluetooth radio at login.
  # systemd-rfkill saves that block, and the next boot restores it before the
  # Intel firmware loads, so the controller disappears.
  dconf.settings = lib.mkIf isNiri {
    "org/blueman/general".plugin-list = [ "!KillSwitch" ];
  };
  # The blueman package also ships an XDG autostart entry, which starts a
  # second applet in every session of a machine that offers niri, Plasma
  # included, where bluedevil owns Bluetooth. The unit above is the only applet.
  xdg.configFile."autostart/blueman.desktop" = lib.mkIf isNiri {
    text = ''
      [Desktop Entry]
      Hidden=true
    '';
  };

  home.packages = lib.optionals isNiri [
    pkgs.brightnessctl
    pkgs.libsecret
    pkgs.wireplumber
    pkgs.wlogout
  ];
}
