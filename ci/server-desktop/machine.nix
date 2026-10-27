# What the desktop test changes on the host's own node, and no more: more
# memory and cores, a second network card that stands for tailscale0, the
# dummy video driver that qemu-vm replaces, and the workload of the CPU
# measurements.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Content for the measurements. The page is 20000 lines of text that a
  # scroll moves over; the video is 20 s of a synthetic 1080p test pattern in
  # VP9, which Chromium decodes in software on a host with no GPU.
  workload =
    pkgs.runCommand "streamed-desktop-workload"
      {
        nativeBuildInputs = [ pkgs.ffmpeg ];
      }
      ''
        mkdir $out
        {
          echo '<html><head><title>SDPAGE</title></head><body style="font:20px monospace">'
          for i in $(seq 20000); do echo "line $i of the scrolling page, with some text on it<br>"; done
          echo '</body></html>'
        } > $out/page.html
        ffmpeg -loglevel error -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 20 \
          -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 4M $out/video.webm
        echo '<html><head><title>SDVIDEO</title></head><body style="margin:0"><video src="video.webm" autoplay loop muted style="width:100vw;height:100vh"></video></body></html>' > $out/video.html
      '';
  # The scroll loop and the browser of the CPU measurements. They run as oruc
  # in the X display that the caller names in DISPLAY.
  scroll = pkgs.writeShellScript "scroll" ''
    ${pkgs.xdotool}/bin/xdotool mousemove 960 600
    while true; do
      ${pkgs.xdotool}/bin/xdotool click --repeat 40 --delay 50 5
      ${pkgs.xdotool}/bin/xdotool click --repeat 40 --delay 50 4
    done
  '';
  # XFCE's session manager restarts a client that dies, and a killed Chromium
  # would come back, so Chromium does not join the session.
  browse = pkgs.writeShellScript "browse" ''
    unset SESSION_MANAGER
    exec ${pkgs.chromium}/bin/chromium --user-data-dir="$(mktemp -d /tmp/sd-chromium.XXXXXX)" --no-first-run \
      --no-default-browser-check --password-store=basic --disable-gpu --window-position=0,0 --window-size=1920,1080 \
      --app="file:///etc/streamed-desktop/workload/$1"
  '';
  tailnetAddress = (lib.head config.networking.interfaces.eth2.ipv4.addresses).address;
in
{
  virtualisation = {
    memorySize = 6144;
    cores = 4;
    vlans = [
      1
      2
    ];
    # qemu-vm sets the X resolution from this one.
    resolution = {
      x = 1920;
      y = 1080;
    };
  };

  # eth1 is the public interface. eth2 becomes tailscale0, which the firewall
  # trusts, so that a client on its network reaches the desktop the way a
  # tailnet peer does. Tailscale runs without a tun device, because the
  # renamed card holds its name. services.tailscale.interfaceName would give
  # userspace networking too, but it renames the interface that the firewall
  # trusts. Flags after --tun win.
  services.udev.extraRules = ''SUBSYSTEM=="net", KERNEL=="eth2", NAME="tailscale0"'';
  services.tailscale.extraDaemonFlags = [ "--tun=userspace-networking" ];
  systemd.network.networks."05-tailnet-test" = {
    matchConfig.Name = "tailscale0";
    address = [ "${tailnetAddress}/24" ];
  };

  # qemu-vm replaces the video driver with modesetting, but the box runs the
  # dummy driver.
  services.xserver.videoDrivers = lib.mkOverride 5 [ "dummy" ];

  environment.etc = {
    "streamed-desktop/workload".source = workload;
    "streamed-desktop/cpu.py".source = ./cpu.py;
    "streamed-desktop/scroll".source = scroll;
    "streamed-desktop/browse".source = browse;
  };
  environment.systemPackages = with pkgs; [
    xinput
    xterm
  ];
}
