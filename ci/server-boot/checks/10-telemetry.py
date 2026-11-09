
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
for tel_signal in ["traces", "logs"]:
    tel_status_code = machine.succeed(
        "curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' "
        f"-d '{{}}' http://127.0.0.1:4318/v1/{tel_signal}"
    )
    assert tel_status_code == "404", f"the local OTLP HTTP port answered {tel_status_code} for {tel_signal}"


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

machine.succeed("logger -t audisp-syslog telemetry-no-ship-probe")
machine.sleep(15)
machine.succeed(f"test ! -s {tel_dir}/logs.json")

for tel_attribute in ["host.name", "host.id"]:
    assert tel_attr("metrics.json", tel_attribute, BOX_HOST) > 0, f"the sink lacks {tel_attribute} in metrics.json"
assert tel_attr("metrics.json", "deployment.environment.name", "development") > 0, "the sink lacks the environment on metrics"

tel_run = "journalctl _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value opentelemetry-collector.service) --no-pager -o cat"
machine.succeed(f"{tel_run} | grep -F 'Everything is ready'")
machine.fail(f"{tel_run} | grep -E '[[:space:]]error[[:space:]]'")
