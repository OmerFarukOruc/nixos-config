dnsserver.start()
acme.start()
tsapi.start()
dnsserver.wait_for_open_port(53)
acme.wait_for_open_port(443)
tsapi.wait_for_open_port(443)
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

import json as fb_json

# The bots' login (nixosModules/fleet-bots-pin.nix). The timer is armed, and the
# unit's directory is ready for the pin.
machine.succeed("systemctl is-active fleet-bots-pin.timer")
# The test starts each run itself, so a timer run cannot overlap one.
machine.succeed("systemctl stop fleet-bots-pin.timer")
machine.succeed("test \"$(stat -c '%a %U %G' /home/oruc/.ssh)\" = '700 oruc oruc'")
# The key that the host ships parses as an SSH public key.
machine.succeed("ssh-keygen -l -f /etc/fleet-bots-test/host.pub | grep -F '(ED25519)'")
# The real tailscale CLI exits non-zero for a peer it does not know, which is
# what the stand-in of the test does for the pin's fallback.
machine.fail("tailscale ip -4 risoluto-bots-1")

fb_sshd_refusal = "with correct key but not from a permitted host"
fb_pub = machine.succeed("cat /etc/fleet-bots-test/bot_key.pub").strip()
fb_keys = "/home/oruc/.ssh/authorized_keys"


def fb_line(ip):
    return f'from="{ip}",no-agent-forwarding,no-X11-forwarding,no-port-forwarding {fb_pub}'


def fb_state(devices, fail=False):
    state = fb_json.dumps({"devices": devices, "fail": fail, "log": []})
    tsapi.succeed(f"cat > /var/lib/tsapi/state.json <<'EOF'\n{state}\nEOF")


def fb_device(label, node, addresses, online, tagged=True):
    return {
        "name": f"{label}.tailnet-test.ts.net",
        "nodeId": node,
        "addresses": addresses,
        "tags": ["tag:grok-box"] if tagged else [],
        "connectedToControl": online,
        "lastSeen": "2026-10-27T10:00:00Z",
    }


def fb_labels():
    state = fb_json.loads(tsapi.succeed("cat /var/lib/tsapi/state.json"))
    return {d["nodeId"]: d["name"].split(".")[0] for d in state["devices"]}, state["log"]


def fb_run():
    # Runs in quick succession would hit the unit's start limit (5 in 10 s),
    # which the 5-minute timer never does. reset-failed clears the counter.
    machine.succeed("systemctl reset-failed fleet-bots-pin.service")
    status, _ = machine.execute("systemctl start fleet-bots-pin.service")
    machine.succeed("journalctl --sync")
    log = machine.succeed(
        "journalctl -o cat --no-pager _SYSTEMD_INVOCATION_ID="
        "$(systemctl show -p InvocationID --value fleet-bots-pin.service)"
    )
    return status, log


def fb_login(source):
    # sshd sees the source address that the client binds, as it sees the
    # tailnet address of a bot. The loopback network answers for all of 127/8.
    return machine.execute(
        f"ssh -b {source} -p 2222 -i /etc/fleet-bots-test/bot_key -o BatchMode=yes -o IdentitiesOnly=yes "
        "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR oruc@127.0.0.1 id -un"
    )


def fb_refusals():
    return int(machine.succeed(f"journalctl -b -u sshd.service -o cat | grep -c '{fb_sshd_refusal}' || true"))


def fb_file_state():
    return machine.succeed(f"stat -c '%a %U %G %i' {fb_keys}").strip()


# The tailnet knows the peer under its name, and the daemon reports its
# address. The token exchange needs the credential that sops-nix rendered.
fb_state([fb_device("risoluto-bots-1", "nBOTS1CNTRL", ["100.64.0.7", "fd7a:115c:a1e0::7"], True)])
machine.succeed("echo 127.0.0.2 > /run/fake-tailscale-ip")
status, log = fb_run()
assert status == 0, f"the first pin failed:\n{log}"
assert "pinned oruc's bot key to risoluto-bots-1 at 127.0.0.2" in log, log
assert machine.succeed(f"cat {fb_keys}").strip() == fb_line("127.0.0.2")
assert fb_file_state().startswith("600 oruc oruc "), fb_file_state()
_, api_log = fb_labels()
assert "token issued" in api_log and "token refused: wrong client" not in api_log, api_log

# The bot logs in from the pinned address, and the same key is refused from any
# other. The refusal names the from= restriction, so a wrong key does not pass
# for it.
code, out = fb_login("127.0.0.2")
assert code == 0 and out.strip() == "oruc", f"the bot's login failed: {code} {out}"
before = fb_refusals()
code, out = fb_login("127.0.0.3")
assert code != 0, "the bot's key logged in from an address that is not pinned"
assert fb_refusals() == before + 1, "sshd did not refuse the key for its address"

# The address does not change, so a run writes nothing.
fb_before = fb_file_state()
status, log = fb_run()
assert status == 0 and "pinned" not in log, log
assert fb_file_state() == fb_before, "an unchanged pin rewrote the file"

# The machine logs in to the tailnet again and gets another address. The next
# run follows it, and the old address no longer logs in.
machine.succeed("echo 127.0.0.3 > /run/fake-tailscale-ip")
status, log = fb_run()
assert status == 0 and "at 127.0.0.3" in log, log
assert machine.succeed(f"cat {fb_keys}").strip() == fb_line("127.0.0.3")
code, out = fb_login("127.0.0.3")
assert code == 0 and out.strip() == "oruc", f"the login from the new address failed: {code} {out}"
before = fb_refusals()
code, out = fb_login("127.0.0.2")
assert code != 0, "the bot's key still logs in from its old address"
assert fb_refusals() == before + 1, "sshd did not refuse the old address"

# A file whose mode or owner drifted is repaired, even when the line is right.
machine.succeed(f"chmod 644 {fb_keys} && chown root:root {fb_keys}")
status, log = fb_run()
assert status == 0 and "pinned" in log, log
assert fb_file_state().startswith("600 oruc oruc "), fb_file_state()

# oruc swapped the key directory for a symlink. The run refuses to write
# through it, and the unit fails.
machine.succeed("mv /home/oruc/.ssh /home/oruc/ssh-moved && ln -s ssh-moved /home/oruc/.ssh")
status, log = fb_run()
machine.succeed("rm /home/oruc/.ssh && mv /home/oruc/ssh-moved /home/oruc/.ssh")
assert status != 0 and "/home/oruc/.ssh is a symlink" in log, log

# The daemon does not know the peer, as in a tailscaled restart. The pin keeps
# its line, and the unit does not fail, so the bots keep their login.
machine.succeed("rm /run/fake-tailscale-ip")
fb_before = machine.succeed(f"cat {fb_keys}")
status, log = fb_run()
assert status == 0 and "kept the current pin" in log, log
assert machine.succeed(f"cat {fb_keys}") == fb_before
code, out = fb_login("127.0.0.3")
assert code == 0, "the pin lost the login when the daemon knew no address"

# Without the credential file the run skips the rename and pins the address
# that the daemon reports, so the bots keep their login before the secret
# exists. The tailnet holds a node the helper would rename.
fb_exec = machine.succeed("systemctl show -p ExecStart --value fleet-bots-pin.service")
fb_cred = fb_exec.split("argv[]=")[1].split(" ;")[0].split()[-1]
assert fb_cred.startswith("/run/secrets"), fb_exec
fb_state(
    [
        fb_device("risoluto-bots-1", "nOLDCNTRL", ["127.0.0.4"], False),
        fb_device("risoluto-bots-1-1", "nNEWCNTRL", ["127.0.0.5"], True),
    ]
)
machine.succeed("echo 127.0.0.7 > /run/fake-tailscale-ip")
machine.succeed(f"mv {fb_cred} {fb_cred}.away")
status, log = fb_run()
machine.succeed(f"mv {fb_cred}.away {fb_cred}")
assert status == 0 and "at 127.0.0.7" in log, log
assert machine.succeed(f"cat {fb_keys}").strip() == fb_line("127.0.0.7")
labels, api_log = fb_labels()
assert api_log == [] and labels["nNEWCNTRL"] == "risoluto-bots-1-1", (labels, api_log)
machine.succeed("rm /run/fake-tailscale-ip")

# The peer logged in while its old node was still registered, so it came back as
# risoluto-bots-1-1. The helper gives it the name back, retires the offline
# nodes that hold the name or a numbered one, leaves a node that lacks the tag,
# and its address pins, with no help from the daemon.
fb_state(
    [
        fb_device("risoluto-bots-1", "nOLDCNTRL", ["127.0.0.4"], False),
        fb_device("risoluto-bots-1-1", "nNEWCNTRL", ["127.0.0.5", "fd7a:115c:a1e0::5"], True),
        fb_device("risoluto-bots-1-3", "nSTALECNTRL", ["127.0.0.6"], False),
        fb_device("risoluto-bots-1-2", "nOTHERCNTRL", ["127.0.0.8"], False, tagged=False),
        fb_device("laptop", "nLAPTOPCNTRL", ["100.64.0.9"], True, tagged=False),
    ]
)
status, log = fb_run()
assert status == 0 and "at 127.0.0.5" in log, log
assert machine.succeed(f"cat {fb_keys}").strip() == fb_line("127.0.0.5")
labels, _ = fb_labels()
assert labels == {
    "nOLDCNTRL": "risoluto-bots-1-retired-noldcntrl",
    "nNEWCNTRL": "risoluto-bots-1",
    "nSTALECNTRL": "risoluto-bots-1-retired-nstalecntrl",
    "nOTHERCNTRL": "risoluto-bots-1-2",
    "nLAPTOPCNTRL": "laptop",
}, labels
code, out = fb_login("127.0.0.5")
assert code == 0 and out.strip() == "oruc", f"the login from the renamed node's address failed: {code} {out}"

# An online node holds the name. The helper renames nothing back, retires the
# offline numbered node, and the pin follows the daemon's address.
fb_state(
    [
        fb_device("risoluto-bots-1", "nNEWCNTRL", ["127.0.0.5"], True),
        fb_device("risoluto-bots-1-4", "nGONECNTRL", ["127.0.0.9"], False),
    ]
)
machine.succeed("echo 127.0.0.5 > /run/fake-tailscale-ip")
status, log = fb_run()
assert status == 0, log
labels, _ = fb_labels()
assert labels == {"nNEWCNTRL": "risoluto-bots-1", "nGONECNTRL": "risoluto-bots-1-retired-ngonecntrl"}, labels
assert machine.succeed(f"cat {fb_keys}").strip() == fb_line("127.0.0.5")

# Two numbered nodes are online and none holds the name. The helper cannot tell
# which one is the bots' machine, so it renames nothing and fails the unit, and
# the pin follows the daemon's address.
fb_state(
    [
        fb_device("risoluto-bots-1-1", "nAONECNTRL", ["127.0.0.10"], True),
        fb_device("risoluto-bots-1-2", "nATWOCNTRL", ["127.0.0.11"], True),
    ]
)
machine.succeed("echo 127.0.0.12 > /run/fake-tailscale-ip")
status, log = fb_run()
assert status != 0 and "2 online nodes named risoluto-bots-1-<n>" in log, log
assert "at 127.0.0.12" in log, log
labels, _ = fb_labels()
assert labels == {"nAONECNTRL": "risoluto-bots-1-1", "nATWOCNTRL": "risoluto-bots-1-2"}, labels

# The Tailscale API is down. The pin still follows the daemon's address, and the
# unit fails so that the journal (and the collector) shows it.
fb_state([fb_device("risoluto-bots-1", "nNEWCNTRL", ["127.0.0.5"], True)], fail=True)
machine.succeed("echo 127.0.0.6 > /run/fake-tailscale-ip")
status, log = fb_run()
assert status != 0, "the unit passed with the Tailscale API down"
assert "Tailscale API 500 on /oauth/token" in log, log
assert "at 127.0.0.6" in log, log
assert machine.succeed(f"cat {fb_keys}").strip() == fb_line("127.0.0.6")
machine.succeed("systemctl reset-failed fleet-bots-pin.service")
