dnsserver.start()
acme.start()
dnsserver.wait_for_open_port(53)
acme.wait_for_open_port(443)
machine.start()
machine.wait_for_unit("multi-user.target")
# --wait returns once boot ends, also when some unit failed.
machine.execute("systemctl is-system-running --wait")
dp_failed = machine.succeed("systemctl --failed --no-legend --plain | cut -d' ' -f1").split()
for dp_unit in dp_failed:
    print(f"journal of {dp_unit}:\n" + machine.succeed(f"journalctl -u {dp_unit} -b -o cat --no-pager | tail -n 40"))
assert dp_failed == [], f"units failed after boot: {dp_failed}"
# A unit with Restart=on-failure that failed shows as activating (auto-restart),
# not as failed, until its next try. The ACME order units retry after 15
# minutes, so a failed order is not in the list above.
dp_restarting = machine.succeed("systemctl list-units --state=activating --no-legend --plain | cut -d' ' -f1").split()
for dp_unit in dp_restarting:
    print(f"journal of {dp_unit}:\n" + machine.succeed(f"journalctl -u {dp_unit} -b -o cat --no-pager | tail -n 40"))
assert dp_restarting == [], f"units still starting or restarting after boot: {dp_restarting}"
# The test CA signed the certificates, and Caddy (restarted by the module after
# a renewal) serves them.
for dp_name in ["openchamber", "herdr", "herdr-fleet"]:
    # The chmod of acme.nix waited, so the race this test holds open happened.
    machine.succeed(f"journalctl -b -u acme-order-renew-{dp_name}.risoluto.dev -o cat | grep -q 'test: chmod of out waited'")
    machine.succeed(f"openssl x509 -noout -issuer -in /var/lib/acme/{dp_name}.risoluto.dev/cert.pem | grep -i pebble")
    machine.wait_until_succeeds(f"openssl s_client -connect 127.0.0.1:443 -servername {dp_name}.risoluto.dev < /dev/null 2> /dev/null | openssl x509 -noout -issuer | grep -i pebble")

# Home Manager's units of oruc. systemd splits an Environment= value at a space
# unless it is quoted, so stay-green would get a schedule without its hours.
dp_uid = machine.succeed("id -u oruc").strip()
machine.wait_for_unit("default.target", "oruc")


def dp_user_env(unit):
    return machine.succeed(
        f"runuser -u oruc -- env XDG_RUNTIME_DIR=/run/user/{dp_uid} systemctl --user show -p Environment --value {unit}"
    )


assert '"STAY_GREEN_SCHEDULE=Mon-Fri 09:00-18:00"' in dp_user_env("stay-green.service"), dp_user_env("stay-green.service")
assert "CLIPROXY_RENDERED_CONFIG=/run/secrets/rendered/cliproxy-config.yaml" in dp_user_env("cliproxy.service")
