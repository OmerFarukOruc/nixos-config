
import json as tel_json
import re
import shlex as tel_shlex

tel_dir = "/var/lib/telemetry-sink"

for unit in ["opentelemetry-collector", "telemetry-sink", "auditd", "audit-rules-nixos"]:
    machine.wait_for_unit(f"{unit}.service")

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
assert re.search(r"path=/nix/store/[^ ]+-sudo-[^ ]+/bin/sudo .*key=sudo-exec", tel_rules), "the sudo rule does not watch the sudo binary"
machine.succeed("systemctl restart suid-sgid-wrappers.service")
assert "key=sudo-exec" in machine.succeed("auditctl -l"), "recreating /run/wrappers dropped the sudo rule"

machine.succeed(f"sshd -T -C user={BOX_USER},host=x,addr=127.0.0.1 | grep -Fix 'loglevel verbose'")

machine.wait_until_succeeds("curl -sf http://127.0.0.1:13133")
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
    machine.wait_until_succeeds(f"grep -q -- {tel_shlex.quote(text)} {tel_dir}/{file}")


def tel_count(file, pattern):
    return int(machine.succeed(f"{{ grep -o -- {tel_shlex.quote(pattern)} {tel_dir}/{file} || true; }} | wc -l"))


def tel_attr(file, key, value):
    return tel_count(file, f'"key":"{key}","value":{{"stringValue":"{value}"}}')


def tel_batches(file):
    batches = []
    out = ""

    def tel_whole(_last_try):
        nonlocal out
        out = machine.succeed(f"cat {tel_dir}/{file}")
        return out.endswith("\n")

    retry(tel_whole)
    for line in out.splitlines():
        try:
            batch = tel_json.loads(line)
        except tel_json.JSONDecodeError as err:
            raise AssertionError(
                f"{file} holds a line that is not JSON ({err.msg} at character {err.pos} of a"
                f" {len(line)}-character line, {len(out)} characters in the file):"
                f" {line[max(0, err.pos - 200):err.pos + 200]!r}"
            ) from err
        batches.append(batch)
    return batches


def tel_records(file):
    records = []
    for batch in tel_batches(file):
        for resource_logs in batch.get("resourceLogs", []):
            resource = {a["key"]: a["value"].get("stringValue") for a in resource_logs["resource"]["attributes"]}
            for scope_logs in resource_logs["scopeLogs"]:
                for record in scope_logs["logRecords"]:
                    body = {f["key"]: f["value"].get("stringValue") for f in record["body"].get("kvlistValue", {}).get("values", [])}
                    records.append((resource, body))
    return records


machine.succeed(f"install -d -m 0755 -o {BOX_USER} -g {BOX_USER} /home/{BOX_USER}")
machine.succeed(f"install -d -m 0700 -o {BOX_USER} -g {BOX_USER} /home/{BOX_USER}/.ssh")
machine.succeed("ssh-keygen -q -t ed25519 -N '' -f /tmp/probe_key")
machine.succeed(f"install -m 0600 -o {BOX_USER} -g {BOX_USER} /tmp/probe_key.pub /home/{BOX_USER}/.ssh/authorized_keys")


def tel_probe(name):
    machine.succeed(
        "printf test | ssh -p 2222 -i /tmp/probe_key -o StrictHostKeyChecking=no "
        f"-o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR {BOX_USER}@127.0.0.1 "
        f"'/run/wrappers/bin/sudo -S -p sudo: touch /etc/{name}'"
    )
    machine.succeed(f"rm -f /etc/{name}")


tel_probe("telemetry-probe-1")
tel_wait("logs.json", "telemetry-probe-1")

tel_credstore = "type=SYSCALL[^}]*comm=.\\{1,2\\}cat.\\{1,2\\}[^}]*key=.\\{1,2\\}credstore"


def tel_credstore_read():
    seen = tel_count("logs.json", tel_credstore)
    machine.execute("runuser -u nobody -- cat /run/secrets/network-dns-1")
    retry(lambda _last_try: tel_count("logs.json", tel_credstore) > seen)


tel_credstore_read()
tel_excluded = ["NETFILTER_CFG", "ANOM_PROMISCUOUS", "BPF"]
tel_before = {t: tel_count("logs.json", f"type={t} msg=audit") for t in tel_excluded}
machine.succeed("iptables -N tel-probe && iptables -X tel-probe")
machine.succeed("ip link set lo promisc on && ip link set lo promisc off")
machine.succeed("systemd-run --wait -p IPAddressDeny=any true")
tel_credstore_read()
for tel_type in tel_excluded:
    assert tel_count("logs.json", f"type={tel_type} msg=audit") == tel_before[tel_type], (
        f"the sink got {tel_type} records of system processes"
    )

machine.succeed("systemctl stop opentelemetry-collector.service")
tel_probe("telemetry-probe-2")
machine.sleep(3)
machine.succeed("systemctl start opentelemetry-collector.service")
tel_wait("logs.json", "telemetry-probe-2")

machine.succeed("systemctl start telemetry-unit-probe.service")
tel_wait("logs.json", "telemetry-unit-probe-line")
tel_wait("metrics.json", "system.memory.usage")
tel_wait("metrics.json", "tlscheck.time_left")
tel_time_left = [
    int(point.get("asInt", point.get("asDouble", 0)))
    for batch in tel_batches("metrics.json")
    for resource_metrics in batch.get("resourceMetrics", [])
    for scope_metrics in resource_metrics["scopeMetrics"]
    for metric in scope_metrics["metrics"]
    if metric["name"] == "tlscheck.time_left"
    for point in metric["gauge"]["dataPoints"]
]
assert tel_time_left and all(0 < seconds <= 3650 * 86400 for seconds in tel_time_left), (
    f"tlscheck.time_left of the 3650-day test certificate: {tel_time_left}"
)

tel_uid = machine.succeed(f"id -u {BOX_USER}").strip()
machine.succeed(f"systemctl start user@{tel_uid}.service")
machine.succeed(f"systemctl --user -M {BOX_USER}@ start telemetry-user-probe.service")
machine.wait_until_succeeds(
    "journalctl -b _SYSTEMD_USER_UNIT=telemetry-user-probe.service PRIORITY=7 -o cat | grep -Fx telemetry-user-probe-debug"
)
tel_wait("logs.json", "telemetry-user-probe-info")
tel_wait("logs.json", "Finished telemetry-user-probe.service")
tel_user_records = [
    (resource, body)
    for resource, body in tel_records("logs.json")
    if "telemetry-user-probe" in body.get("MESSAGE", "")
]
tel_own = [
    r for r in tel_user_records
    if r[1]["MESSAGE"] == "telemetry-user-probe-info" and r[1].get("_SYSTEMD_USER_UNIT") == "telemetry-user-probe.service"
]
assert len(tel_own) == 1, f"the sink did not get exactly the info line of the user unit: {tel_user_records}"
assert tel_own[0][1].get("_UID") == tel_uid, f"the user unit line is not from {BOX_USER}: {tel_own[0][1]}"
assert tel_own[0][0].get("service.name") == "infra-units", "the user unit line lacks service.name infra-units"
tel_manager = [
    r for r in tel_user_records
    if r[1].get("USER_UNIT") == "telemetry-user-probe.service" and r[1]["MESSAGE"].startswith("Finished ")
]
assert len(tel_manager) == 1, f"the sink did not get exactly the Finished line of the user manager: {tel_user_records}"
assert not any(b["MESSAGE"] == "telemetry-user-probe-debug" for _, b in tel_user_records), "the debug line of the user unit shipped"

assert tel_count("logs.json", f"Accepted publickey for {BOX_USER}") == 2, "the sink did not get exactly the 2 sshd login lines"

for tel_key in ["sudo-exec", "etc-change"]:
    tel_wait("logs.json", f"type=SYSCALL[^}}]*auid=1003[^}}]*key=.\\{{1,2\\}}{tel_key}")

assert tel_attr("logs.json", "service.name", "host-audit") > 0, "the sink has no host-audit logs"
for tel_file in ["logs.json", "metrics.json"]:
    for tel_attribute in ["host.name", "host.id"]:
        assert tel_attr(tel_file, tel_attribute, BOX_HOST) > 0, f"the sink lacks {tel_attribute} in {tel_file}"
assert tel_attr("metrics.json", "deployment.environment.name", "development") > 0, "the sink lacks the environment on metrics"

tel_run = "journalctl _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value opentelemetry-collector.service) --no-pager -o cat"
machine.succeed(f"{tel_run} | grep -F 'Everything is ready'")
machine.fail(f"{tel_run} | grep -E '[[:space:]]error[[:space:]]'")
