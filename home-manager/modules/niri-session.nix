{
  config,
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

  scheme = config.scheme.withHashtag;
  inherit (config.oruc.theme) isLight;
  # The icons are light lavender images, so a light scheme draws its buttons
  # in the darkest slots.
  button = {
    background = if isLight then scheme.base05 else scheme.base01;
    color = if isLight then scheme.base00 else scheme.base05;
    active = if isLight then scheme.base04 else scheme.base02;
  };
  wlogoutIcons = "${pkgs.wlogout}/share/wlogout/icons";
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

  programs.wlogout = lib.mkIf isNiri {
    enable = true;
    style = ''
      * {
        background-image: none;
        box-shadow: none;
      }

      window {
        background-color: rgba(${config.scheme."base00-rgb-r"}, ${config.scheme."base00-rgb-g"}, ${config.scheme."base00-rgb-b"}, 0.9);
      }

      button {
        border-radius: 0;
        border-color: ${scheme.base03};
        color: ${button.color};
        background-color: ${button.background};
        border-style: solid;
        border-width: 1px;
        background-repeat: no-repeat;
        background-position: center;
        background-size: 25%;
      }

      button:focus, button:active, button:hover {
        background-color: ${button.active};
        border-color: ${scheme.base0D};
        outline-style: none;
      }
    ''
    +
      lib.concatMapStrings
        (name: ''

          #${name} {
            background-image: image(url("${wlogoutIcons}/${name}.png"));
          }
        '')
        [
          "lock"
          "logout"
          "suspend"
          "hibernate"
          "shutdown"
          "reboot"
        ];
  };
}
