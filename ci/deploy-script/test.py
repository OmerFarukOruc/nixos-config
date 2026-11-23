import shlex

checkout = f"/home/{USER}/nixos-config"
other = f"/home/{USER}/other"
state = f"/home/{USER}/.local/state/nixos-config-deploy"
profile = "/nix/var/nix/profiles/system"

machine.start()
machine.wait_for_unit("multi-user.target")
machine.wait_for_unit("sshd.service")
machine.wait_for_unit("tailscaled.service")
machine.wait_until_succeeds(f"systemctl --user -M {USER}@ is-active --quiet session-test.service ignored-test.service")
machine.succeed(f"nix-env --profile {profile} --set /run/current-system")

systems = {
    name: machine.succeed(f"readlink -f /run/current-system/specialisation/{name}").strip()
    for name in machine.succeed("ls /run/current-system/specialisation").split()
}


def as_user(command):
    return machine.succeed(f"runuser -l {USER} -c {shlex.quote(command)}").strip()


def publish(name, directory=checkout):
    path = systems[name]
    flake = (
        "{\n"
        "  outputs = _: {\n"
        f"    nixosConfigurations.{HOST}.config.system.build.toplevel =\n"
        f'      builtins.appendContext "{path}" {{ "{path}" = {{ path = true; }}; }};\n'
        "  };\n"
        "}\n"
    )
    machine.succeed(f"cat > {directory}/flake.nix <<'EOF'\n{flake}EOF\nchown {USER}: {directory}/flake.nix")
    as_user(f"cd {directory} && git add -A && git commit -q -m {name}")


def deploy(action, directory=checkout, options=""):
    status, out = machine.execute(
        f"runuser -l {USER} -c {shlex.quote(f'cd {directory} && ./deploy.sh {options} {HOST} {action}')} 2>&1"
    )
    print(f"deploy.sh {options} {HOST} {action} from {directory} exited {status}; its output ends:")
    print("\n".join(f"  | {line[:240]}" for line in out.splitlines()[-16:]))
    return status, out


def running():
    return machine.succeed("readlink -f /run/current-system").strip()


def boot_default():
    return machine.succeed(f"readlink -f {profile}").strip()


def assert_on_good(phase):
    assert running() == systems["good"], f"{phase}: the good system does not run"
    assert boot_default() == systems["good"], f"{phase}: the good system is not the boot default"
    machine.fail("systemctl is-active --quiet deploy-rollback.timer")


def loader_is_signed():
    return machine.execute(f"sbverify --cert {signing_certificate} {loader}")[0] == 0


machine.succeed(
    f"install -d -m 0700 {signing_key.rsplit('/', 1)[0]}"
    f" && openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 2 -subj '/CN=deploy-script/'"
    f" -keyout {signing_key} -out {signing_certificate}"
)
machine.copy_from_host(deploy_sh, "/tmp/deploy.sh")
as_user(
    f"mkdir {checkout} && cd {checkout} && git init -q -b main"
    " && git config --global user.name test && git config --global user.email test@example.invalid"
    " && install -m 0755 /tmp/deploy.sh deploy.sh"
    " && echo '{\"nodes\":{\"root\":{}},\"root\":\"root\",\"version\":7}' > flake.lock"
    " && echo first > notes.txt"
    " && mkdir sub && echo inside > sub/file && ln -s sub link"
)
publish("good")
as_user(f"git clone -q {checkout} {other}")

print("phase: a good system")
as_user(f"cd {checkout} && echo second > notes.txt")
publish("good")
status, out = deploy("switch")
assert status == 0, "the deploy of the good system failed"
assert "Deployment completed" in out
assert_on_good("good")
machine.succeed(f"grep -qx 'system={systems['good']}' \"$(readlink -f {state}/current).source\"")
machine.succeed("test -s /boot/limine/limine.conf")
assert loader_is_signed(), "the install of the good system left Limine unsigned"

print("phase: another deploy holds the lock")
held = f"flock {state}/deploy.lock sh -c 'cd {checkout} && ./deploy.sh {HOST} test'"
status, out = machine.execute(f"runuser -l {USER} -c {shlex.quote(held)} 2>&1")
print(out[-600:])
assert status == 77, f"a held lock gave exit {status}, not 77"
assert f"Another deploy to {HOST} is running" in out

print("phase: a rollback timer is still pending")
machine.succeed("systemd-run --unit=deploy-rollback --on-active=600 true")
status, out = deploy("test")
assert status == 70, f"a pending rollback timer gave exit {status}, not 70"
machine.succeed("systemctl stop deploy-rollback.timer")

print("phase: a system with an ordering cycle")
publish("cycle")
status, out = deploy("switch")
assert status == 80, f"an ordering cycle gave exit {status}, not 80"
assert "would not finish booting" in out
assert_on_good("cycle")

print("phase: a system that breaks sshd")
publish("broken")
status, out = deploy("switch")
assert status == 4, f"a system that breaks sshd gave exit {status}, not 4"
assert "Restoring the previous system now" in out, "the deploy did not roll back"
assert "THE ROLLBACK FAILED" not in out, "the deploy reported a working restore as failed"
assert_on_good("broken")
machine.wait_for_unit("sshd.service")

print("phase: a system that breaks sshd, and a restore that fails")
publish("restorefail")
machine.succeed("touch /run/deploy-test-restore-fails")
status, out = deploy("switch")
assert status == 4, f"a system that breaks sshd gave exit {status}, not 4"
assert "THE ROLLBACK FAILED (deploy-rollback.service result: 4)" in out, "the deploy did not report the failed restore"
recorded = machine.succeed("cat /run/deploy-rollback.status").split()
assert recorded[1:] == ["4"], f"the restore recorded {recorded}, not status 4"
machine.succeed("systemctl is-active --quiet deploy-rollback.timer")
machine.succeed("unlink /run/deploy-test-restore-fails")
machine.succeed("systemctl stop deploy-rollback.timer")
machine.succeed("systemctl start restore-blocker.service")
assert_on_good("restorefail")
machine.wait_for_unit("sshd.service")

print("phase: a system that breaks a session service")
publish("session")
status, out = deploy("switch")
assert status == 75, f"a broken session service gave exit {status}, not 75"
assert "These session services broke after the switch: session-test.service" in out
assert "ignored-test" not in out, "the session check did not ignore ignored-test.service"
assert "THE ROLLBACK FAILED" not in out, "the deploy reported a working restore as failed"
assert_on_good("session")
machine.succeed(f"systemctl --user -M {USER}@ restart session-test.service ignored-test.service")

print("phase: a system whose boot entries fail to install")
menu = machine.succeed("cat /boot/limine/limine.conf")
publish("bootfail")
status, out = deploy("switch")
assert status == 73, f"a failed boot entry install gave exit {status}, not 73"
assert f"The boot default is {systems['good']} again." in out
assert running() == systems["bootfail"], "the candidate does not keep running"
assert boot_default() == systems["good"], "the good system is not the boot default again"
links = machine.succeed(f"for l in {profile}-*-link; do readlink -f $l; done").split()
assert systems["bootfail"] not in links, "the failed generation stays in the system profile"
assert machine.succeed("cat /boot/limine/limine.conf") == menu, "the boot menu is not the one before the deploy"
publish("good")
status, out = deploy("switch")
assert status == 0, "the deploy back to the good system failed"
assert_on_good("back to good")

print("phase: a system whose install leaves a declared boot loader unsigned")
publish("unsigned")
status, out = deploy("switch")
assert status == 73, f"an unsigned boot loader gave exit {status}, not 73"
assert f"{loader} carries no signature" in out
assert f"The boot default is {systems['good']} again." in out
assert boot_default() == systems["good"], "the good system is not the boot default again"
assert loader_is_signed(), "the restore left Limine unsigned"
publish("good")
status, out = deploy("switch")
assert status == 0, "the deploy back to the good system failed"
assert_on_good("back to good after unsigned")

print("phase: a checkout that lacks a file of the running release")
status, out = deploy("switch", other)
assert status == 78, f"a deploy that drops a file gave exit {status}, not 78"
dropped = out.split("so this deploy would drop them:\n", 1)[-1].splitlines()
assert [line for line in dropped if line.startswith("  ")] == ["  notes.txt"], (
    "the deploy does not name exactly the file it would drop"
)
assert_on_good("drop")
status, out = deploy("switch", other, "--replace")
assert status == 0, "the deploy with --replace failed"
assert_on_good("replace")

print("phase: the deploy loses its wait for the activation, which then succeeds")
publish("dropped")
status, out = deploy("switch")
assert status == 0, f"a lost wait for a working activation gave exit {status}, not 0"
ended = machine.succeed("journalctl -b -u client-ender.service -o cat | sed -n 's/^client-ender: ended \\([0-9]*\\) clients$/\\1/p'")
assert ended.split() and all(int(n) >= 1 for n in ended.split()), f"client-ender ended no client: {ended!r}"
assert "deploy-activate recorded status 0." in out, "the deploy did not read the status the activation recorded"
assert "Restoring the previous system" not in out, "the deploy rolled back a working activation"
assert running() == systems["dropped"], "the candidate does not keep running"
assert boot_default() == systems["dropped"], "the candidate is not the boot default"
machine.fail("systemctl is-active --quiet deploy-rollback.timer")
