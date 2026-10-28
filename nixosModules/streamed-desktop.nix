# A light XFCE desktop for a server with no screen, reached only over the
# tailnet through xrdp: each RDP login of oruc starts an X server with the
# xorgxrdp driver and an XFCE session of its own, with H.264 where the client
# supports it. Nothing runs before the first login, so the box has no display
# manager and the netcup console keeps its login on tty1.
# The firewall (nixosModules/tailscale.nix) opens no port on the public
# interface, so xrdp answers on tailscale0 only; an assertion there fails the
# evaluation when a port gets opened. Turns on with `features.streamedDesktop`
# of the machine record.
{
  config,
  lib,
  pkgs,
  ...
}:
lib.mkIf config.oruc.machine.features.streamedDesktop {
  # H.264 and the Turkish keyboard layout come from overlays/xrdp.nix.
  nixpkgs.overlays = [ (import ../overlays/xrdp.nix) ];

  # The screensaver would lock an idle session, and an RDP login or reconnect
  # asks for oruc's password already.
  services.xserver.desktopManager.xfce = {
    enable = true;
    enableScreensaver = false;
  };

  services.xrdp = {
    enable = true;
    # Each session has its own bus. sesman starts a second session for oruc
    # when a client asks for another color depth (Policy=Default in its
    # sesman.ini), and a second xfce4-session on oruc's systemd user bus ends
    # at once.
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
