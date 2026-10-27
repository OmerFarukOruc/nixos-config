# The telemetry module: the collector, auditd, and the records that a login over
# SSH, sudo, a read of a secret by another user and a restart of the collector
# leave in the sink of modules/telemetry.nix. The collector exports to that sink
# and not to the central endpoint, so TLS and the real endpoint are not covered.

import re
import shlex as tel_shlex

tel_dir = "/var/lib/telemetry-sink"

for unit in ["opentelemetry-collector", "telemetry-sink", "auditd", "audit-rules-nixos"]:
    machine.wait_for_unit(f"{unit}.service")

# Audit records reach the journal through auditd's syslog plugin, so journald
# must not read the audit socket.
machine.fail("systemctl is-active --quiet systemd-journald-audit.socket")
tel_status = machine.succeed("auditctl -s")
assert re.search(r"^enabled 1$", tel_status, re.M), "the kernel does not audit"
assert re.search(r"^backlog_limit 8192$", tel_status, re.M), "the audit backlog is not 8192"

tel_rules = machine.succeed("auditctl -l")
for tel_key in [
    "unit-change",
    "sudo-change",
    "ssh-config",
    "audit-config",
    "identity",
    "etc-change",
    "sudo-exec",
    "credstore",
]:
    assert f"key={tel_key}" in tel_rules, f"auditctl lists no rule with the key {tel_key}"
assert "path=/run/wrappers/bin/sudo" in tel_rules, "the sudo rule does not watch the wrapper"
assert tel_rules.count("always,exclude") == 3, "auditctl does not list 3 excludes"

machine.succeed("sshd -T -C user=oruc,host=x,addr=127.0.0.1 | grep -Fix 'loglevel verbose'")

# The unit is active before the collector answers its health check.
machine.wait_until_succeeds("curl -sf http://127.0.0.1:13133", timeout=60)
tel_log = "journalctl -u opentelemetry-collector.service -b --no-pager -o cat"
machine.succeed(f"{tel_log} | grep -F 'Everything is ready'")
machine.fail(f"{tel_log} | grep -E '[[:space:]]error[[:space:]]'")

machine.succeed(r"ss -Htln | grep -E '127\.0\.0\.1:4318 '")
machine.fail(r"ss -Htln | grep -E '(0\.0\.0\.0|\*|\[::\]):4318 '")
tel_status_code = machine.succeed(
    "curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' "
    "-d '{}' http://127.0.0.1:4318/v1/metrics"
)
assert tel_status_code == "200", f"the local OTLP HTTP port answered {tel_status_code}"


def tel_wait(file, text):
    machine.wait_until_succeeds(f"grep -q -- {tel_shlex.quote(text)} {tel_dir}/{file}", timeout=60)


def tel_count(file, pattern):
    # grep exits 1 for no match, which would end the check before its message.
    return int(machine.succeed(f"{{ grep -o -- {tel_shlex.quote(pattern)} {tel_dir}/{file} || true; }} | wc -l"))


# The count of an OTLP attribute with its value. The string risoluto-dev-1 alone
# would also match _HOSTNAME and the hostname that resourcedetection adds.
def tel_attr(file, key, value):
    return tel_count(file, f'"key":"{key}","value":{{"stringValue":"{value}"}}')


# A login of oruc over SSH, then sudo as oruc changes a file under /etc. The
# session has a login id, which the etc-change rule needs.
machine.succeed("install -d -m 0755 -o oruc -g oruc /home/oruc")
machine.succeed("install -d -m 0700 -o oruc -g oruc /home/oruc/.ssh")
machine.succeed("ssh-keygen -q -t ed25519 -N '' -f /tmp/probe_key")
machine.succeed("install -m 0600 -o oruc -g oruc /tmp/probe_key.pub /home/oruc/.ssh/authorized_keys")


def tel_probe(name):
    machine.succeed(
        "printf test | ssh -p 2222 -i /tmp/probe_key -o StrictHostKeyChecking=no "
        "-o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR oruc@127.0.0.1 "
        f"'/run/wrappers/bin/sudo -S -p sudo: touch /etc/{name}'"
    )
    machine.succeed(f"rm -f /etc/{name}")


tel_probe("telemetry-probe-1")
tel_wait("logs.json", "telemetry-probe-1")

# A user other than root reads a secret, which the credstore rule logs although
# the read fails.
machine.execute("runuser -u nobody -- cat /run/secrets/network-dns-1")

# The collector is down while a second login and sudo happen. Its cursor in the
# file store must give it the records afterwards.
machine.succeed("systemctl stop opentelemetry-collector.service")
tel_probe("telemetry-probe-2")
machine.sleep(3)
machine.succeed("systemctl start opentelemetry-collector.service")
tel_wait("logs.json", "telemetry-probe-2")

machine.succeed("systemctl start telemetry-unit-probe.service")
tel_wait("logs.json", "telemetry-unit-probe-line")
tel_wait("metrics.json", "system.memory.usage")

# Two logins, so two lines. A third would mean the restart sent the journal
# again.
assert tel_count("logs.json", "Accepted publickey for oruc") == 2, "the sink did not get exactly the 2 sshd login lines"

# A SYSCALL record exists only for a call that matched a rule. The CONFIG_CHANGE
# records that load the rules carry the keys too.
for tel_key in ["sudo-exec", "etc-change"]:
    assert (
        tel_count("logs.json", f"type=SYSCALL[^}}]*auid=1003[^}}]*key=.\\{{1,2\\}}{tel_key}") > 0
    ), f"the sink has no SYSCALL record of the {tel_key} rule"
assert (
    tel_count("logs.json", "type=SYSCALL[^}]*comm=.\\{1,2\\}cat.\\{1,2\\}[^}]*key=.\\{1,2\\}credstore") > 0
), "the sink has no SYSCALL record of the credstore rule"

assert tel_attr("logs.json", "service.name", "host-audit") > 0, "the sink has no host-audit logs"
assert tel_attr("logs.json", "service.name", "infra-units") > 0, "the sink has no infra-units logs"
for tel_file in ["logs.json", "metrics.json"]:
    for tel_attribute in ["host.name", "host.id"]:
        assert tel_attr(tel_file, tel_attribute, "risoluto-dev-1") > 0, f"the sink lacks {tel_attribute} in {tel_file}"
assert tel_attr("metrics.json", "deployment.environment.name", "development") > 0, "the sink lacks the environment on metrics"

# Stopping the collector makes its journald receivers log an error when
# journalctl dies first, so only the run after the restart counts. The first
# run's start is checked above.
tel_run = "journalctl _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value opentelemetry-collector.service) --no-pager -o cat"
machine.succeed(f"{tel_run} | grep -F 'Everything is ready'")
machine.fail(f"{tel_run} | grep -E '[[:space:]]error[[:space:]]'")
