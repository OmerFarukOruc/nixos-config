import json
import re
from datetime import timedelta

SD_ENV = "XDG_RUNTIME_DIR=/run/user/1003 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1003/bus XAUTHORITY=/home/oruc/.Xauthority"
SD_PORT = 3389

dnsserver.start()
acme.start()
dnsserver.wait_for_open_port(53)
acme.wait_for_open_port(443)
machine.start()
client.start()
machine.wait_for_unit("multi-user.target")
machine.wait_for_unit("xrdp.service")
machine.wait_for_unit("xrdp-sesman.service")
client.wait_for_x()
client.succeed("xauth merge /home/alice/.Xauthority")


def sd_oruc(command, display=":10", background=False):
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
    return dict((line.split("=", 1)[1].split(".")[0], line.split()[0]) for line in out.splitlines() if "DISPLAY=" in line)


def sd_diagnose():
    """Prints what a failed wait needs to be read."""
    print(machine.execute("ps -eo user,pid,args | grep -E 'Xorg|xfce|xfwm|xrdp' | grep -v grep | cut -c1-200")[1])
    print(machine.execute("loginctl list-sessions --no-legend")[1])
    print(machine.execute("journalctl -u xrdp -u xrdp-sesman -b -o cat --no-pager | tail -n 60")[1])


machine.execute("systemctl is-system-running --wait")
sd_failed = machine.succeed("systemctl --failed --no-legend --plain | cut -d' ' -f1").split()
for sd_unit in sd_failed:
    print(f"journal of {sd_unit}:\n" + machine.succeed(f"journalctl -u {sd_unit} -b -o cat --no-pager | tail -n 40"))
assert sd_failed == [], f"units failed after boot: {sd_failed}"
sd_activating = [
    unit
    for unit in machine.succeed("systemctl list-units --state=activating --no-legend --plain | cut -d' ' -f1").split()
    if not unit.endswith("eth2.device")
]
assert sd_activating == [], f"units still starting after boot: {sd_activating}"

assert sd_session_pids("xfce4-session") == {}, sd_session_pids("xfce4-session")

print(machine.succeed(f"ss -Hltnup | grep -E ':{SD_PORT} ' || true"))

machine.wait_until_succeeds(f"ss -Hltn 'sport = :{SD_PORT}' | grep -q LISTEN")
client.fail(f"nc -z -w 3 {SD_PUBLIC_ADDRESS} {SD_PORT}")
client.succeed(f"nc -z -w 5 {SD_TAILNET_ADDRESS} {SD_PORT}")
machine.succeed(f"iptables -I nixos-fw -p tcp --dport {SD_PORT} -j nixos-fw-accept")
client.succeed(f"nc -z -w 5 {SD_PUBLIC_ADDRESS} {SD_PORT}")
machine.succeed(f"iptables -D nixos-fw -p tcp --dport {SD_PORT} -j nixos-fw-accept")
client.fail(f"nc -z -w 3 {SD_PUBLIC_ADDRESS} {SD_PORT}")
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
    print(machine.execute(f"runuser -u oruc -- env {SD_ENV} systemctl --user stop sd-workload.slice 2>&1")[1])
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
    result["pixels_changed_per_second"] = changed
    if page is not None:
        client.screenshot(f"cpu-{route}-{load.replace(' ', '-')}")
        sd_workload_stop()
    print(f"SDRESULT {route} / {load}: {json.dumps(result)}")
    SD_RESULTS.setdefault(route, {})[load] = result


def sd_conditions(route, display):
    machine.sleep(10)
    sd_measure(route, "idle desktop", display)
    sd_measure(route, "scrolling page", display, "page.html", True)
    sd_measure(route, "video 1080p", display, "video.html")


SD_RDP = f"xfreerdp /v:{SD_TAILNET_ADDRESS} /u:oruc /p:test /cert:ignore /size:1920x1080 /gfx:AVC420 /wm-class:sdrdp /log-level:INFO"
client.execute(f"setsid {SD_RDP} > /tmp/rdp-1.log 2>&1 &")
sd_wait_session(":10")
machine.sleep(10)
client.screenshot("rdp-xfce-first")
sd_first = sd_session_pids("xfce4-session")
print("xfce4-session by display after the first login:", sd_first)
assert set(sd_first) == {":10"}, sd_first
sd_xrandr = sd_oruc("xrandr --current")
print(sd_xrandr)
assert "current 1920 x 1080" in sd_xrandr, "the RDP session is not 1920x1080"
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

sd_layout = [line for line in sd_xrdp_log().splitlines() if "xrdp_load_keyboard_layout" in line]
print("\n".join(sd_layout))
assert "keylayout:[0x0000041F]" in sd_layout[-2] and "layout [tr]" in sd_layout[-1], "the session did not get the client's Turkish layout"
sd_window = dict(
    line.split("=", 1) for line in client.succeed("DISPLAY=:0 xdotool search --onlyvisible --class sdrdp getwindowgeometry --shell").splitlines()
)
print("FreeRDP window:", sd_window)


def sd_client_point(x, y):
    return f"{int(sd_window['X']) + x} {int(sd_window['Y']) + y}"


# FreeRDP's X11 client sends a pointer move only when the next input event
# reaches it (its trace log in a run of this test), so a move alone may never
# reach the desktop. A click carries its own position.
client.succeed(f"DISPLAY=:0 xdotool mousemove {sd_client_point(900, 700)} click 1")
machine.sleep(2)
sd_mouse = sd_oruc("xdotool getmouselocation")
print("pointer of the desktop:", sd_mouse)
sd_pointer = dict(item.split(":") for item in sd_mouse.split())
assert (sd_pointer["x"], sd_pointer["y"]) == ("900", "700"), sd_mouse
# xev on the desktop prints the keysym of each key that reaches it, which
# shows the layout without a terminal's locale in the way. A click focuses it.
# The client sends the Turkish letters by keycode, as a keyboard does: keycodes
# 31, 47 and 34 are ı, ş and ğ on the Turkish layout and i, ; and [ on us.
sd_oruc("sh -c 'stdbuf -oL xev -name SDTYPE -geometry 600x300+200+200 -event keyboard > /tmp/sd-xev.txt'", background=True)
machine.wait_until_succeeds(f"runuser -u oruc -- env DISPLAY=:10 {SD_ENV} xwininfo -root -tree | grep -q SDTYPE", timeout=timedelta(seconds=30))
machine.sleep(3)
client.succeed(f"DISPLAY=:0 xdotool mousemove {sd_client_point(400, 300)} click 1")
client.sleep(1)
client.succeed("DISPLAY=:0 xdotool type --delay 150 abcdefgh")
client.succeed("DISPLAY=:0 xdotool key --delay 150 31 47 34 Return")
try:
    machine.wait_until_succeeds("grep -q 'keysym 0xff0d, Return' /tmp/sd-xev.txt", timeout=timedelta(seconds=30))
except Exception:
    print("client focus:", client.execute("DISPLAY=:0 xdotool getwindowfocus getwindowname")[1])
    print("desktop focus:", sd_oruc("xdotool getwindowfocus getwindowname"))
    print(client.execute("tail -n 30 /tmp/rdp-2.log")[1])
    client.screenshot("rdp-typing-failed")
    raise
sd_keys = re.findall(r"KeyPress event.*?\(keysym 0x[0-9a-f]+, (\w+)\)", machine.succeed("cat /tmp/sd-xev.txt"), re.S)
print("keys of the desktop:", sd_keys)
assert sd_keys == [*"abcdefgh", "idotless", "scedilla", "gbreve", "Return"], sd_keys
client.screenshot("rdp-xfce-typed")

sd_conditions("xrdp", ":10")

print("SDRESULTS " + json.dumps(SD_RESULTS))
