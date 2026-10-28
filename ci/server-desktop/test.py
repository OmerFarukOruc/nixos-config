import json
from datetime import timedelta

SD_ENV = "XDG_RUNTIME_DIR=/run/user/1003 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1003/bus XAUTHORITY=/home/oruc/.Xauthority"
SD_TCP_PORTS = [3389, 47984, 47989, 47990, 48010]
# Moonlight runs as alice, in her X and audio session, the way a user runs it.
# 1000 is alice's uid (nixos/tests/common/user-account.nix).
SD_ALICE_ENV = "DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
SD_ALICE = f"runuser -u alice -- env {SD_ALICE_ENV}"

dnsserver.start()
acme.start()
dnsserver.wait_for_open_port(53)
acme.wait_for_open_port(443)
machine.start()
client.start()
machine.wait_for_unit("multi-user.target")
machine.wait_for_unit("display-manager.service")
machine.wait_for_unit("xrdp.service")
machine.wait_for_unit("xrdp-sesman.service")
machine.wait_for_unit("sunshine.service", "oruc")
client.wait_for_x()
client.succeed("xauth merge /home/alice/.Xauthority")


def sd_oruc(command, display=":0", background=False):
    """Runs a command as oruc, in the X session of this display."""
    full = f"runuser -u oruc -- env DISPLAY={display} {SD_ENV} {command}"
    if background:
        machine.execute(f"setsid {full} > /dev/null 2>&1 &")
        return ""
    return machine.succeed(full)


def sd_session_pids(program):
    """Maps the X display of each oruc process of this program to its pid."""
    out = machine.succeed(
        f"for p in $(pgrep -u oruc -f {program}); do echo $p $(tr '\\0' '\\n' < /proc/$p/environ | grep '^DISPLAY='); done"
    )
    # xrdp sets DISPLAY to :10.0 and LightDM to :0.
    return dict((line.split("=", 1)[1].split(".")[0], line.split()[0]) for line in out.splitlines() if "DISPLAY=" in line)


def sd_diagnose():
    """Prints what a failed wait needs to be read."""
    print(machine.execute("ps -eo user,pid,args | grep -E 'lightdm|Xorg|xfce|xfwm|sunshine|xrdp' | grep -v grep | cut -c1-200")[1])
    print(machine.execute("loginctl list-sessions --no-legend")[1])
    print(machine.execute("journalctl -u display-manager -b -o cat --no-pager | tail -n 40")[1])
    print(machine.execute("tail -n 30 /var/log/lightdm/*.log")[1])
    print(machine.execute("tail -n 30 /var/log/X.0.log")[1])
    print(machine.execute("journalctl _SYSTEMD_USER_UNIT=sunshine.service -b -o cat --no-pager | tail -n 40")[1])


# The units are healthy with the desktop running, as in the units test.
machine.execute("systemctl is-system-running --wait")
sd_failed = machine.succeed("systemctl --failed --no-legend --plain | cut -d' ' -f1").split()
for sd_unit in sd_failed:
    print(f"journal of {sd_unit}:\n" + machine.succeed(f"journalctl -u {sd_unit} -b -o cat --no-pager | tail -n 40"))
assert sd_failed == [], f"units failed after boot: {sd_failed}"
# The test renames eth2 to tailscale0, so the device units that the test
# framework made for eth2 never come up.
sd_activating = [
    unit
    for unit in machine.succeed("systemctl list-units --state=activating --no-legend --plain | cut -d' ' -f1").split()
    if not unit.endswith("eth2.device")
]
assert sd_activating == [], f"units still starting after boot: {sd_activating}"

# The login session of the Sunshine route runs XFCE on the dummy driver.
# The nixpkgs wrappers rename the binaries, so match the command line.
try:
    machine.wait_until_succeeds("pgrep -u oruc -f xfce4-session", timeout=timedelta(seconds=120))
    machine.wait_until_succeeds("pgrep -u oruc -f xfwm4", timeout=timedelta(seconds=60))
except Exception:
    sd_diagnose()
    raise
# LightDM takes VT 7, so that the console keeps its login on tty1.
print(machine.succeed("pgrep -af ' :0 .*vt[0-9]'"))
machine.succeed("pgrep -af ' :0 .*vt7'")
machine.succeed("systemctl is-active getty@tty1.service")
print(machine.succeed("grep -E 'Driver|Modeline|Virtual|dummy' /var/log/X.0.log | head -n 20 || true"))
sd_xrandr = sd_oruc("xrandr --current")
print(sd_xrandr)
assert "DUMMY0 connected" in sd_xrandr and "1920x1080+0+0" in sd_xrandr, "the desktop is not 1920x1080 on the dummy driver"
print(sd_session_pids("xfce4-session"))

# Listening sockets of both routes, for the record.
print(machine.succeed("ss -Hltnup | grep -E ':(3389|4798[0-9]|4799[0-9]|4801[0-9]) ' || true"))

# Public interface and tailnet. A connection through eth1 stands for the
# public interface, where the firewall drops every port of both routes. A
# connection through tailscale0 reaches them. The control rule per port shows
# that the drop comes from the firewall alone.
for sd_port in SD_TCP_PORTS:
    machine.wait_until_succeeds(f"ss -Hltn 'sport = :{sd_port}' | grep -q LISTEN")
    client.fail(f"nc -z -w 3 {SD_PUBLIC_ADDRESS} {sd_port}")
    client.succeed(f"nc -z -w 5 {SD_TAILNET_ADDRESS} {sd_port}")
    machine.succeed(f"iptables -I nixos-fw -p tcp --dport {sd_port} -j nixos-fw-accept")
    client.succeed(f"nc -z -w 5 {SD_PUBLIC_ADDRESS} {sd_port}")
    machine.succeed(f"iptables -D nixos-fw -p tcp --dport {sd_port} -j nixos-fw-accept")
    client.fail(f"nc -z -w 3 {SD_PUBLIC_ADDRESS} {sd_port}")
# UDP ports cannot be probed without a stream, so the rules say what the
# firewall accepts: everything on tailscale0 and lo, replies, and Tailscale's
# own UDP port. A port opened on one interface adds a line to this list.
sd_rules = machine.succeed("iptables -S nixos-fw")
print(sd_rules)
assert [line for line in sd_rules.splitlines() if line.endswith("-j nixos-fw-accept")] == [
    "-A nixos-fw -i tailscale0 -j nixos-fw-accept",
    "-A nixos-fw -i lo -j nixos-fw-accept",
    "-A nixos-fw -m conntrack --ctstate RELATED,ESTABLISHED -j nixos-fw-accept",
    "-A nixos-fw -p udp -m udp --dport 41641 -j nixos-fw-accept",
], "the firewall accepts more than tailscale0, lo, replies and Tailscale's UDP port"
sd_rules6 = machine.succeed("ip6tables -S nixos-fw")
print(sd_rules6)
# NixOS adds ICMPv6 and the DHCPv6 client port on link-local addresses.
assert [line for line in sd_rules6.splitlines() if line.endswith("-j nixos-fw-accept")] == [
    "-A nixos-fw -i tailscale0 -j nixos-fw-accept",
    "-A nixos-fw -i lo -j nixos-fw-accept",
    "-A nixos-fw -m conntrack --ctstate RELATED,ESTABLISHED -j nixos-fw-accept",
    "-A nixos-fw -p udp -m udp --dport 41641 -j nixos-fw-accept",
    "-A nixos-fw -p ipv6-icmp -j nixos-fw-accept",
    "-A nixos-fw -d fe80::/64 -p udp -m udp --dport 546 -j nixos-fw-accept",
], "the IPv6 firewall accepts more than tailscale0, lo, replies, Tailscale's UDP port, ICMPv6 and DHCPv6"



def sd_wait_session(display):
    """Waits until oruc runs xfce4-session on this X display."""
    for _ in range(60):
        if display in sd_session_pids("xfce4-session"):
            return
        machine.sleep(2)
    sd_diagnose()
    raise Exception(f"no XFCE session on display {display}")


def sd_xrdp_log():
    return machine.succeed("journalctl -u xrdp -u xrdp-sesman -b -o cat --no-pager")


# CPU use of the machine, per route, while an idle desktop, a scrolling page
# and a 1080p video are on screen. The workload runs on the machine itself,
# started as oruc in the display of the route, so that both routes carry the
# same load. "no client" is the same load on the login session of the Sunshine
# route with nobody connected: what Chromium and the X server cost alone.
SD_RESULTS = {}


def sd_start_unit(name, display, command):
    """Starts a command as a transient user unit of oruc in this X display. The units share one slice, so that stopping the slice ends every process of the workload."""
    sd_oruc(
        f"systemd-run --user --collect --quiet --slice=sd-workload --unit={name} --setenv=DISPLAY={display} --setenv=XAUTHORITY=/home/oruc/.Xauthority {command}"
    )


def sd_workload(display, page, scrolling):
    sd_start_unit("sd-browser", display, f"/etc/streamed-desktop/browse {page}")
    title = "SDPAGE" if page == "page.html" else "SDVIDEO"
    try:
        machine.wait_until_succeeds(
            f"runuser -u oruc -- env DISPLAY={display} {SD_ENV} xdotool search --onlyvisible --name {title}",
            timeout=timedelta(seconds=120),
        )
    except Exception:
        print(sd_oruc("xwininfo -root -tree", display=display))
        print(machine.execute("ps -eo user,pid,args | grep chromium | grep -v grep | cut -c1-200")[1])
        raise
    machine.sleep(15)
    if scrolling:
        sd_start_unit("sd-scroll", display, "/etc/streamed-desktop/scroll")
        machine.sleep(5)


def sd_workload_stop():
    # The box browser's own Chromium keeps running. A measurement without
    # scrolling has no sd-scroll unit, and systemctl stops nothing when a
    # named unit is not loaded, so the units are stopped through their slice.
    print(machine.execute(f"runuser -u oruc -- env {SD_ENV} systemctl --user stop sd-workload.slice 2>&1")[1])
    # A leftover browser would count against the next measurement.
    try:
        machine.wait_until_fails("pgrep -u oruc -f 'sd-chromium|streamed-desktop/scroll'", timeout=timedelta(seconds=30))
    except Exception:
        print(machine.execute("ps -u oruc -o pid,ppid,etimes,args --forest | cut -c1-170")[1])
        raise
    machine.sleep(3)


def sd_screen_changes(display, name):
    """Counts the pixels that differ between two screenshots of the display one second apart, and keeps the second."""
    sd_oruc(f"import -window root /tmp/{name}-a.png", display=display)
    machine.sleep(1)
    sd_oruc(f"import -window root /tmp/{name}-b.png", display=display)
    machine.copy_from_machine(f"/tmp/{name}-b.png")
    return round(float(machine.execute(f"compare -metric AE /tmp/{name}-a.png /tmp/{name}-b.png null: 2>&1")[1].split()[0]))


def sd_measure(route, load, display, page=None, scrolling=False):
    changed = None
    if page is not None:
        sd_workload(display, page, scrolling)
        shot = f"{route}-{load}".replace(" ", "-")
        changed = sd_screen_changes(display, shot)
        if changed <= 10000:
            print(sd_oruc("xwininfo -root -tree", display=display))
            print(sd_oruc("xdotool getmouselocation", display=display))
            print(sd_oruc("xdotool search --onlyvisible --name SD getwindowgeometry %@", display=display))
            print(machine.execute("pgrep -u oruc -a -f streamed-desktop/scroll; ps -eo user,pid,args | grep -c '[x]dotool click'")[1])
            print(machine.execute(f"identify -format '%k colors, mean %[fx:mean]\\n' /tmp/{shot}-b.png")[1])
        assert changed > 10000, f"{load} on {display} does not move: {changed} pixels changed"
    result = json.loads(machine.succeed("python3 /etc/streamed-desktop/cpu.py 30"))
    if route == "sunshine":
        # A client that aborted mid-cell leaves a number for no stream at all.
        assert "CLIENT DISCONNECTED" not in sd_stream_log(), f"the Moonlight client disconnected during {load}"
    result["pixels_changed_per_second"] = changed
    if page is not None:
        if route != "no client":
            client.screenshot(f"cpu-{route.replace(' ', '-')}-{load.replace(' ', '-')}")
        sd_workload_stop()
    print(f"SDRESULT {route} / {load}: {json.dumps(result)}")
    SD_RESULTS.setdefault(route, {})[load] = result


def sd_conditions(route, display):
    machine.sleep(10)
    sd_measure(route, "idle desktop", display)
    sd_measure(route, "scrolling page", display, "page.html", True)
    sd_measure(route, "video 1080p", display, "video.html")


sd_conditions("no client", ":0")

# RDP: log in as oruc through xrdp, get XFCE, disconnect, reconnect to the
# same session. The client asks for H.264 and xrdp's log says what it used.
SD_RDP = f"xfreerdp /v:{SD_TAILNET_ADDRESS} /u:oruc /p:test /cert:ignore /size:1920x1080 /gfx:AVC420 /log-level:INFO"
client.execute(f"setsid {SD_RDP} > /tmp/rdp-1.log 2>&1 &")
sd_wait_session(":10")
machine.sleep(10)
client.screenshot("rdp-xfce-first")
sd_first = sd_session_pids("xfce4-session")
print("xfce4-session by display after the first login:", sd_first)
assert set(sd_first) == {":0", ":10"}, sd_first
sd_oruc("xterm -title SDMARKER -e sleep 3600", display=":10", background=True)
machine.wait_until_succeeds(f"runuser -u oruc -- env DISPLAY=:10 {SD_ENV} xwininfo -root -tree | grep -q SDMARKER", timeout=timedelta(seconds=30))
sd_log = sd_xrdp_log()
assert "Matched H264 mode" in sd_log and "using x264 for software encoder" in sd_log, "xrdp did not use H.264"
client.succeed("pkill -f '[x]freerdp /v:'")
machine.sleep(5)
assert sd_session_pids("xfce4-session")[":10"] == sd_first[":10"], "the session ended with the connection"
client.execute(f"setsid {SD_RDP} > /tmp/rdp-2.log 2>&1 &")
machine.sleep(15)
client.screenshot("rdp-xfce-reconnected")
sd_second = sd_session_pids("xfce4-session")
assert sd_second == sd_first, (sd_first, sd_second)
assert "reconnected session" in sd_xrdp_log(), "sesman did not reconnect the session"
machine.succeed(f"runuser -u oruc -- env DISPLAY=:10 {SD_ENV} xwininfo -root -tree | grep -q SDMARKER")
print(machine.succeed("ps -eo pid,lstart,args | grep -E 'Xorg :10' | grep -v grep | cut -c1-120"))
print(sd_xrdp_log()[-3000:])


sd_conditions("xrdp", ":10")

# Sunshine: pair a Moonlight client, stream the XFCE desktop of the login
# session, and send mouse and keyboard input from the client.
client.succeed("pkill -f '[x]freerdp /v:'")
sd_oruc("sunshine --creds testuser testpass")
machine.systemctl("restart sunshine.service", "oruc")
machine.wait_for_open_port(47989)
machine.wait_for_open_port(47990)
# The web UI answers on the box only: a tailnet peer gets "forbidden".
sd_web_status = client.succeed(f"curl -sk -o /dev/null -w '%{{http_code}}' https://{SD_TAILNET_ADDRESS}:47990/")
assert sd_web_status == "403", f"the web UI answered a tailnet peer with {sd_web_status}"
client.execute(f"{SD_ALICE} moonlight pair {SD_TAILNET_ADDRESS} --pin 1234 > /tmp/moonlight-pair.log 2>&1 &")
SD_API = "curl --fail --insecure -u testuser:testpass"
for _ in range(30):
    sd_pending = json.loads(machine.succeed(f"{SD_API} https://localhost:47990/api/pin"))
    if sd_pending.get("pairings"):
        break
    machine.sleep(2)
print("pairing requests:", sd_pending)
sd_pair = json.loads(
    machine.succeed(
        f"{SD_API} -H 'Content-Type: application/json' -d '{json.dumps({'pairing_id': sd_pending['pairings'][0]['id'], 'pin': '1234', 'name': 'test'})}' https://localhost:47990/api/pin"
    )
)
# Sunshine answers false when the client did not finish the pairing within its
# ping timeout, so the client's log goes out before the check.
machine.sleep(5)
print(client.succeed("cat /tmp/moonlight-pair.log"))
assert sd_pair["status"] is True, sd_pair

SD_MOONLIGHT = (
    f"{SD_ALICE} moonlight --video-decoder software --video-codec H.264 --1080 --fps 60"
    f" --display-mode borderless --absolute-mouse stream {SD_TAILNET_ADDRESS} Desktop"
)


def sd_sunshine_log():
    return machine.succeed("journalctl _SYSTEMD_USER_UNIT=sunshine.service -b -o cat --no-pager")


def sd_stream_log():
    """The Sunshine log from the moment the client connected, because Sunshine probes its encoders at start-up."""
    log = sd_sunshine_log()
    return log[log.rindex("CLIENT CONNECTED") :]


def sd_stream():
    client.execute(f"setsid {SD_MOONLIGHT} > /tmp/moonlight-stream.log 2>&1 &")
    try:
        machine.wait_until_succeeds(
            "journalctl _SYSTEMD_USER_UNIT=sunshine.service -b -o cat --no-pager | grep -q 'CLIENT CONNECTED'",
            timeout=timedelta(seconds=90),
        )
    except Exception:
        print(sd_sunshine_log()[-4000:])
        print(client.execute("cat /tmp/moonlight-stream.log")[1])
        raise
    machine.sleep(15)


# PipeWire has no sound card in the VM and makes a dummy sink, as on a real
# client with an audio server. Moonlight opens it when the stream starts.
# pactl prints the placeholder @DEFAULT_SINK@ while the server has no default sink yet.
print("default sink of alice:", client.wait_until_succeeds(f"{SD_ALICE} pactl get-default-sink | grep -E '^[^@]'", timeout=timedelta(seconds=60)))
print(client.succeed(f"{SD_ALICE} pactl list short sinks"))
sd_stream()
client.screenshot("moonlight-xfce")
sd_log = sd_stream_log()
print(sd_log[-3000:])
print(client.succeed("tail -n 30 /tmp/moonlight-stream.log"))
# A client that cannot open audio retries every second from its audio thread,
# which is not the path of a real client, and that retry can corrupt the heap
# of Moonlight 6.2.0 (SDL3 allows an audio init and quit on the main thread only).
sd_client_log = client.succeed("cat /tmp/moonlight-stream.log")
print("\n".join(line for line in sd_client_log.splitlines() if "audio" in line.lower()))
for line in ("Obtained audio buffer", "SDL audio driver:"):
    assert line in sd_client_log, f"Moonlight did not open audio: no '{line}' in its log"
for line in ("Failed to open audio device", "Reinitializing audio renderer"):
    assert line not in sd_client_log, f"Moonlight retries its audio device: '{line}' in its log"
assert "Creating encoder [libx264]" in sd_log, "Sunshine did not use the software encoder for the stream"

# Mouse: an absolute move on the client lands on the same spot of the desktop.
client.succeed("DISPLAY=:0 xdotool mousemove 500 400")
client.sleep(2)
client.succeed("DISPLAY=:0 xdotool mousemove 900 700")
machine.sleep(2)
sd_mouse = sd_oruc("xdotool getmouselocation")
print("pointer of the desktop:", sd_mouse)
sd_pointer = dict(item.split(":") for item in sd_mouse.split())
assert abs(int(sd_pointer["x"]) - 900) < 30 and abs(int(sd_pointer["y"]) - 700) < 30, sd_mouse
# Keyboard: a click focuses an xterm of the desktop, and the typed letters
# reach the program in it. The letters sit in the same place on the Turkish
# layout of the desktop.
sd_oruc("xterm -title SDTYPE -geometry 80x10+200+200 -e sh -c 'cat > /tmp/sd-typed.txt'", background=True)
machine.wait_until_succeeds(f"runuser -u oruc -- env DISPLAY=:0 {SD_ENV} xwininfo -root -tree | grep -q SDTYPE", timeout=timedelta(seconds=30))
machine.sleep(3)
# The raw input events that the X server of the desktop gets, for a failure.
machine.execute(f"setsid runuser -u oruc -- env DISPLAY=:0 {SD_ENV} xinput test-xi2 --root > /tmp/sd-xi2.log 2>&1 &")
client.succeed("DISPLAY=:0 xdotool mousemove 400 300 click 1")
client.sleep(1)
# xdotool type takes every later word as text, so the Return key is a command of its own.
client.succeed("DISPLAY=:0 xdotool type --delay 150 abcdefgh")
client.succeed("DISPLAY=:0 xdotool key Return")
try:
    machine.wait_until_succeeds("grep -Fx abcdefgh /tmp/sd-typed.txt", timeout=timedelta(seconds=30))
except Exception:
    print("client focus:", client.execute("DISPLAY=:0 xdotool getwindowfocus getwindowname")[1])
    print(client.execute("DISPLAY=:0 xwininfo -root -tree | head -n 30")[1])
    print(client.execute("DISPLAY=:0 xprop -root _NET_SUPPORTING_WM_CHECK")[1])
    print("desktop focus:", sd_oruc("xdotool getwindowfocus getwindowname"))
    print("desktop pointer:", sd_oruc("xdotool getmouselocation"))
    print(sd_oruc("xinput list"))
    print("typed text:", machine.execute("cat -A /tmp/sd-typed.txt; ls -l /tmp/sd-typed.txt")[1])
    print(machine.execute("grep -A12 'EVENT type 2 ' /tmp/sd-xi2.log | grep -E 'EVENT|device|detail|group' | head -n 60")[1])
    print(sd_oruc("setxkbmap -query"))
    print(machine.execute("pgrep -u oruc -a -f 'xterm|cat'")[1])
    print(sd_sunshine_log()[-2000:])
    print(client.execute("tail -n 30 /tmp/moonlight-stream.log")[1])
    client.screenshot("moonlight-xfce-typing-failed")
    raise
client.screenshot("moonlight-xfce-typed")
sd_conditions("sunshine", ":0")
# The audio device stayed open for the whole stream, with no retry.
sd_client_log = client.succeed("cat /tmp/moonlight-stream.log")
for line in ("Failed to open audio device", "Reinitializing audio renderer"):
    assert line not in sd_client_log, f"Moonlight retried its audio device during the stream: '{line}' in its log"
print("SDRESULTS " + json.dumps(SD_RESULTS))
