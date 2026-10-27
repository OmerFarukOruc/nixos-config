# A light XFCE desktop for a server with no screen, reached only over the
# tailnet, through two routes that Omer compares by CPU use:
# - Sunshine streams the desktop of oruc's login on a virtual X display, and
#   Moonlight on another machine shows it.
# - xrdp starts a desktop of its own for each RDP login, with H.264 where the
#   client supports it.
# The firewall (nixosModules/tailscale.nix) opens no port on the public
# interface, so both routes answer on tailscale0 only; an assertion there fails
# the evaluation when a port gets opened. Turns on with
# `features.streamedDesktop` of the machine record.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  width = 1920;
  height = 1080;
in
lib.mkIf config.oruc.machine.features.streamedDesktop {
  nixpkgs.overlays = [ (import ../overlays/xrdp.nix) ];

  # The Sunshine route: LightDM logs oruc in at boot on an X server with the
  # dummy video driver, which draws into memory and needs no GPU or screen.
  # XFCE itself comes from agent-runtime.nix.
  services.xserver = {
    enable = true;
    videoDrivers = [ "dummy" ];
    # The dummy driver takes any mode inside these limits, and 256000 kB of
    # video memory holds the largest screen that xrandr may ask for.
    deviceSection = "VideoRam 256000";
    monitorSection = ''
      HorizSync 5.0-300.0
      VertRefresh 5.0-120.0
    '';
    virtualScreen = {
      x = width;
      y = height;
    };
    resolutions = [
      {
        x = width;
        y = height;
      }
    ];
    displayManager.lightdm = {
      enable = true;
      # LightDM starts a seat only when logind calls it graphical, which needs
      # display hardware. The dummy driver needs none. nixpkgs sets minimum-vt
      # to 1, and the console getty below needs VT 1 (LightDM takes the first
      # free VT without looking at getty); the later key wins.
      extraConfig = ''
        logind-check-graphical = false
        minimum-vt = 7
      '';
    };
    desktopManager.xfce = {
      enable = true;
      # A lock screen would ask a Moonlight user for oruc's password at the
      # first idle minute. Reaching the stream already needs the tailnet and a
      # paired client.
      enableScreensaver = false;
    };
  };
  services.displayManager = {
    autoLogin = {
      enable = true;
      user = "oruc";
    };
    defaultSession = "xfce";
  };

  # The netcup console keeps its login on tty1, for recovery when the network is
  # down. The display manager module of nixpkgs (display-managers/generic.nix)
  # conflicts with autovt@tty1 for every display manager and has no option to
  # turn that off, and getty.nix stops starting tty1 when a display manager is
  # on, so the conflict is cleared and the getty is asked for again. LightDM
  # still switches the console to its own VT 7 when it starts, so the screen
  # shows no login until Ctrl+Alt+F1.
  systemd.services.display-manager.conflicts = lib.mkForce [ ];
  systemd.targets.getty.wants = [ "autovt@tty1.service" ];

  # The software encoder: the box has no GPU. x11 capture reads the virtual
  # display of the login above. Sunshine runs as a user unit that the session
  # starts through graphical-session.target.
  services.sunshine = {
    enable = true;
    autoStart = true;
    openFirewall = false; # tailscale0 is trusted; nothing else is open
    settings = {
      capture = "x11";
      encoder = "software";
      # The web UI creates its admin account at the first visit and takes the
      # pairing PIN, and Sunshine counts the tailnet's 100.64.0.0/10 as LAN, so
      # its default (lan) would let any tailnet peer claim the account first.
      # Omer reaches the UI through an SSH port forward.
      origin_web_ui_allowed = "pc";
    };
  };

  # The Sunshine module turns Avahi on as a default, so that Moonlight finds a
  # host on its LAN, and Avahi opens UDP 5353 for it. Moonlight reaches this
  # host by its tailnet name, and an open port on the public interface fails
  # the firewall assertion.
  services.avahi.enable = false;

  # The xrdp route. Its Xorg session has the xorgxrdp driver, not the dummy
  # one, and H.264 comes from overlays/xrdp.nix.
  services.xrdp = {
    enable = true;
    # Its own session bus: the login session of the Sunshine route holds the
    # session manager's name on oruc's systemd user bus, and a second
    # xfce4-session on that bus ends at once.
    defaultWindowManager = "${pkgs.dbus}/bin/dbus-run-session xfce4-session";
    openFirewall = false;
    # The module sends xrdp's logs to /dev/null and has no option to change
    # that, and its example for extraConfDirCommands does the same edit. With
    # syslog on, the lines reach the journal that the collector reads. sesman
    # lets root log in by default, and root has a password on this box.
    extraConfDirCommands = ''
      substituteInPlace $out/xrdp.ini --replace-fail EnableSyslog=false EnableSyslog=true
      substituteInPlace $out/sesman.ini \
        --replace-fail EnableSyslog=false EnableSyslog=true \
        --replace-fail AllowRootLogin=true AllowRootLogin=false
    '';
  };
}
