{
  lib,
  osConfig,
  pkgs,
  sessions,
  ...
}:
let
  isNiri = sessions.hasDesktop osConfig.oruc.machine "niri";
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
  # Opening Blueman Manager starts the applet over D-Bus, so in Plasma it puts
  # a second Bluetooth icon next to bluedevil's. Plasma's menu leaves it out.
  # Its adapters entry already shows only in XFCE and MATE.
  xdg.dataFile."applications/blueman-manager.desktop" = lib.mkIf isNiri {
    source = pkgs.runCommand "blueman-manager.desktop" { } ''
      cp ${pkgs.blueman}/share/applications/blueman-manager.desktop $out
      chmod u+w $out
      echo 'NotShowIn=KDE;' >> $out
      grep -qx 'NotShowIn=KDE;' $out
    '';
  };

  home.packages = lib.optionals isNiri [
    pkgs.brightnessctl
    pkgs.libsecret
    pkgs.wireplumber
  ];

  oruc.themeFiles = lib.mkIf isNiri {
    ".config/niri/oruc-theme.kdl" = import ../../nixosModules/niri-theme.nix;
  };
}
