# The web names, the rootless containers and the agent runtime. Variables here
# start with svc_ because all check files share one namespace. The test
# interface with the address of the names, the backends on 3000, 7317 and 7318
# and the probe image come from modules/services.nix.


import json as svc_json
import re as svc_re
import shlex as svc_shlex
import socket as svc_socket
import ssl as svc_ssl

svc_uid = machine.succeed("id -u oruc").strip()
svc_rt = f"/run/user/{svc_uid}"


def svc_oruc(command, timeout=120):
    """Run a shell command as oruc with the user manager's environment."""
    env = f"XDG_RUNTIME_DIR={svc_rt} DBUS_SESSION_BUS_ADDRESS=unix:path={svc_rt}/bus HOME=/home/oruc"
    return machine.succeed(
        f"runuser -u oruc -- env {env} timeout {timeout} bash -c {svc_shlex.quote(command)}"
    )


# Tools that the Cursor worker and the Amp runner drive, from the system or oruc's
# profile (Home Manager gives bubblewrap), and the paths that the
# dotfiles units use.
for svc_tool in [
    "Xvnc",
    "Xvfb",
    "xdotool",
    "xdpyinfo",
    "xrandr",
    "xrdb",
    "xset",
    "xsetroot",
    "xprop",
    "xwininfo",
    "xauth",
    "ffmpeg",
    "magick",
    "bwrap",
    "parallel",
    "labwc",
    "wlr-randr",
    "dbus-run-session",
    "cmake",
    "sqlite3",
    "unzip",
    "tree",
    "python3",
    "startxfce4",
    "xfce4-session",
    "xfwm4",
    "xfce4-panel",
    "xfdesktop",
    "chromium",
    "podman",
    "docker",
]:
    machine.succeed(f"PATH=/etc/profiles/per-user/oruc/bin:$PATH command -v {svc_tool}")
machine.succeed("docker compose version")
# A unit from the dotfiles checkout finds herdr and claude through the PATH
# that those units set, which lists the Home Manager profile.
svc_unit_path = (
    "/home/oruc/.local/bin:/etc/profiles/per-user/oruc/bin:/usr/local/bin:/usr/bin:/bin"
)
svc_found = svc_oruc(
    f"systemd-run --user --quiet --wait --pipe --collect -p Environment=PATH={svc_unit_path} "
    "/usr/bin/zsh -c 'command -v herdr claude'"
)
assert svc_found.split() == [
    "/etc/profiles/per-user/oruc/bin/herdr",
    "/etc/profiles/per-user/oruc/bin/claude",
], f"herdr and claude are not in the profile: {svc_found!r}"
svc_usr_path = "env -i PATH=/usr/local/bin:/usr/bin:/bin"
for svc_name in ["zsh", "bash"]:
    machine.succeed(
        f"runuser -u oruc -- {svc_usr_path} /usr/bin/{svc_name} -c 'exit 0'"
    )
machine.succeed(f"runuser -u oruc -- {svc_usr_path} /usr/bin/systemctl --version")
machine.succeed(f"runuser -u oruc -- {svc_usr_path} /usr/bin/podman --version")

# The token comes through sops-nix, and each name has its certificate request,
# with the token as a credential and the flag that skips the resolvers' check.
machine.succeed("test $(stat -c '%a' /run/secrets/cloudflare-acme-dns-token) = 400")
machine.succeed(
    "grep -Fx test-token-not-for-cloudflare /run/secrets/cloudflare-acme-dns-token"
)
for svc_site in ["openchamber", "herdr", "herdr-fleet"]:
    svc_unit = f"acme-order-renew-{svc_site}.risoluto.dev.service"
    svc_cat = machine.succeed(f"systemctl cat {svc_unit}")
    assert "LoadCredential=CLOUDFLARE_DNS_API_TOKEN_FILE:" in svc_cat, (
        f"{svc_site} has no DNS token credential"
    )
    svc_script = machine.succeed(
        f"grep -oE '/nix/store/[^ ]*' <<< \"$(systemctl show -p ExecStart --value {svc_unit})\" | head -n 1"
    ).strip()
    machine.succeed(f"grep -F -e --dns.propagation.disable-rns {svc_script}")
    machine.succeed(
        f"openssl x509 -noout -subject -in /var/lib/acme/{svc_site}.risoluto.dev/cert.pem | grep -F {svc_site}.risoluto.dev"
    )

# Caddy listens on every address and proxies each name.
machine.wait_for_unit("caddy.service")
machine.succeed("ss -Htln | grep -E ':443 '")
for svc_port in [3000, 7317, 7318]:
    machine.wait_for_open_port(svc_port)


def svc_site_headers(name):
    """The headers that the backend of a site received for a request that carries a forged Tailscale-User-Login."""
    return machine.succeed(
        f"curl -sk --max-time 10 --resolve {name}.risoluto.dev:443:127.0.0.1 "
        f"-H 'Tailscale-User-Login: probe@example.com' https://{name}.risoluto.dev/"
    ).lower()


# Caddy removes a Tailscale-User-Login header that a client sends, because the
# herdr web UI takes it for the identity that tailscale serve sets. The proxied
# request still reaches the backend, which shows in the headers Caddy adds.
# Every one of 15 requests per name must pass, with no retry.
svc_backends = {"openchamber": 3000, "herdr": 7317, "herdr-fleet": 7318}
for svc_site in list(svc_backends) * 15:
    svc_headers = svc_site_headers(svc_site)
    assert f"x-backend-port: {svc_backends[svc_site]}\n" in svc_headers, (
        f"{svc_site} reached another backend: {svc_headers!r}"
    )
    assert "x-forwarded-for:" in svc_headers, (
        f"{svc_site} did not proxy: {svc_headers!r}"
    )
    assert "tailscale-user-login" not in svc_headers, (
        f"{svc_site} passes a forged Tailscale-User-Login on"
    )
for svc_site in ["openchamber", "herdr", "herdr-fleet"]:
    machine.succeed(
        f"echo | openssl s_client -connect 127.0.0.1:443 -servername {svc_site}.risoluto.dev 2>/dev/null"
        f" | openssl x509 -noout -subject | grep -F {svc_site}.risoluto.dev"
    )


# A client outside the VM reaches Caddy through eth0, where the firewall drops
# port 443, because only tailscale0 is trusted. The control rule shows that the
# forwarded connection works, so the drop comes from the firewall alone.
def svc_tls_handshake():
    context = svc_ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = svc_ssl.CERT_NONE
    try:
        with svc_socket.create_connection(("127.0.0.1", 12443), timeout=5) as conn:
            with context.wrap_socket(conn, server_hostname="openchamber.risoluto.dev"):
                return True
    except OSError:
        return False


machine.forward_port(12443, 443)
assert not svc_tls_handshake(), "Caddy answers outside the tailnet interface"
machine.succeed("iptables -I nixos-fw -p tcp --dport 443 -j nixos-fw-accept")
assert svc_tls_handshake(), "the forwarded connection does not reach Caddy"
machine.succeed("iptables -D nixos-fw -p tcp --dport 443 -j nixos-fw-accept")

# The /tmp cleanup keeps the sockets and the tmux directories of agents.
svc_tmpfiles = machine.succeed("systemd-tmpfiles --cat-config")
for svc_path in ["/tmp/tmux-*", "/tmp/.X11-unix", "/tmp/.ICE-unix"]:
    assert svc_re.search(
        rf"^'?x'? '?{svc_re.escape(svc_path)}'? ", svc_tmpfiles, svc_re.M
    ), f"systemd-tmpfiles has no x rule for {svc_path}"

# Rootless Docker and Podman answer as oruc on their user sockets.
machine.wait_until_succeeds(f"test -S {svc_rt}/docker.sock", timeout=180)
machine.wait_until_succeeds(
    f"curl -s --max-time 10 --unix-socket {svc_rt}/podman/podman.sock http://d/_ping | grep -Fx OK",
    timeout=180,
)
machine.succeed(
    f"curl -s --max-time 10 --unix-socket {svc_rt}/docker.sock http://d/_ping | grep -Fx OK"
)
machine.succeed(
    f"stat -c '%U' {svc_rt}/docker.sock {svc_rt}/podman/podman.sock | sort -u | grep -Fx oruc"
)
svc_docker = f"docker --host unix://{svc_rt}/docker.sock"
svc_info = svc_oruc(f"{svc_docker} info --format '{{{{json .SecurityOptions}}}}'")
assert "rootless" in svc_info, "dockerd does not run rootless"
svc_oruc(
    f"podman --url unix://{svc_rt}/podman/podman.sock info --format '{{{{.Host.Security.Rootless}}}}' | grep -Fx true"
)
svc_oruc(
    "grep -F defaultMaxUsedSpace $(systemctl --user show docker.service -p ExecStart"
    " | grep -oE -- '--config-file=[^ ;]+' | head -n 1 | cut -d= -f2)"
)

# The host's own outbound ports stay clear of the ports that Docker publishes
# from, and a published container answers on the port Docker picked. A container
# runs under each engine and through /usr/bin/podman.
machine.succeed("sysctl -n net.ipv4.ip_local_port_range | grep -E '^61000\\s+65535$'")
svc_oruc(f"{svc_docker} load -i /etc/server-boot/probe-image.tar")
svc_cid = svc_oruc(
    f"{svc_docker} run -d --rm -p 127.0.0.1::8080 probe:1 httpd -f -p 8080 -h /bin"
).strip()
svc_port = int(
    svc_oruc(
        f"{svc_docker} port {svc_cid} 8080/tcp | head -n 1 | sed 's/.*://'"
    ).strip()
)
assert svc_port < 61000, f"docker published port {svc_port}, inside the host's range"
machine.wait_until_succeeds(
    f"curl -s --max-time 5 -o /dev/null -w '%{{http_code}}' http://127.0.0.1:{svc_port}/busybox | grep -Fx 200"
)
svc_oruc(f"{svc_docker} rm -f {svc_cid}")
# A client from an address other than loopback, as a tailnet peer is, makes
# RootlessKit 3 try to keep the client's source address (--source-ip-transparent,
# on by default), which it never tries for a loopback client. Here the client
# uses the host's own global address.
svc_addr = machine.succeed(
    "ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -n 1"
).strip()
svc_cid = svc_oruc(
    f"{svc_docker} run -d --rm -p 8080 probe:1 httpd -f -p 8080 -h /bin"
).strip()
svc_port = int(
    svc_oruc(
        f"{svc_docker} port {svc_cid} 8080/tcp | head -n 1 | sed 's/.*://'"
    ).strip()
)
machine.wait_until_succeeds(
    f"curl -s --max-time 5 -o /dev/null -w '%{{http_code}}' http://{svc_addr}:{svc_port}/busybox | grep -Fx 200"
)
svc_oruc(f"{svc_docker} rm -f {svc_cid}")
svc_podman_docker = f"env DOCKER_HOST=unix://{svc_rt}/podman/podman.sock docker"
svc_oruc(f"{svc_podman_docker} load -i /etc/server-boot/probe-image.tar")
svc_oruc(f"{svc_podman_docker} run --rm probe:1 echo podman-ok | grep -Fx podman-ok")
machine.succeed(
    f"runuser -u oruc -- {svc_usr_path} HOME=/home/oruc XDG_RUNTIME_DIR={svc_rt} "
    "timeout 120 /usr/bin/podman run --rm probe:1 echo podman-direct-ok | grep -Fx podman-direct-ok"
)

# The box browser, and the Chromium of nixpkgs' Playwright that oruc's session
# variables point to.
machine.wait_until_succeeds(
    f"runuser -u oruc -- env XDG_RUNTIME_DIR={svc_rt} DBUS_SESSION_BUS_ADDRESS=unix:path={svc_rt}/bus box-browser status",
    timeout=180,
)
# Xvnc of the box browser has no password and listens on loopback only.
machine.succeed(r"ss -Htln | grep -E '127\.0\.0\.1:5920 '")
machine.fail(r"ss -Htln | grep -E '(0\.0\.0\.0|\*|\[::\]):5920 '")

svc_hm_vars = "/etc/profiles/per-user/oruc/etc/profile.d/hm-session-vars.sh"
svc_oruc(
    f'. {svc_hm_vars} && test -n "$PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS" && '
    "$PLAYWRIGHT_BROWSERS_PATH/chromium-*/chrome-linux64/chrome --headless --disable-gpu --no-sandbox "
    "--dump-dom 'data:text/html,<p>playwright-ok</p>' 2>/dev/null | grep -F '<p>playwright-ok</p>'"
)

# CLIProxyAPI and stay-green are off here (they need a registry and a Teams
# sign-in), so only their secrets are checked; the units test checks their
# unit settings, because Home Manager's units fail here. sops-nix
# renders cliproxy's config as JSON with both API keys and the management key,
# readable by oruc only.
for svc_file in ["cliproxy-config.yaml", "cliproxy.env"]:
    machine.succeed(f"test \"$(stat -c '%U %a' /run/secrets/rendered/{svc_file})\" = 'oruc 400'")
svc_cliproxy = svc_json.loads(svc_oruc("cat /run/secrets/rendered/cliproxy-config.yaml"))
assert svc_cliproxy["api-keys"] == ["test-api-key-omer", "test-api-key-friend"], svc_cliproxy["api-keys"]
assert svc_cliproxy["remote-management"]["secret-key"] == "test-management-key"
svc_oruc("grep -Fx CLIPROXY_SHARE_HOST=cliproxy.example.ts.net /run/secrets/rendered/cliproxy.env")
