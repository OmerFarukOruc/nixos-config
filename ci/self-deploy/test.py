import textwrap

dp_state = "/root/.local/state/nixos-config-deploy"
dp_systems = ["good", "broken", "initrd"]

machine.start()
machine.wait_for_unit("multi-user.target")

for dp_timer in ["self-deploy", "self-deploy-reboot"]:
    machine.succeed(f"systemctl is-active --quiet {dp_timer}.timer")
dp_calendar = lambda timer: machine.succeed(f"systemctl show -p TimersCalendar {timer}.timer")
assert "00/2:30:00 UTC" in dp_calendar("self-deploy"), "the deploy calendar is not in UTC"
assert "02:10:00 UTC" in dp_calendar("self-deploy-reboot"), "the reboot calendar is not 02:10 UTC"
machine.succeed("systemctl mask --runtime --now self-deploy.timer self-deploy-reboot.timer")

assert machine.succeed("systemctl show self-deploy.service -p User --value").strip() == "root"
assert "DEPLOY_REPOSITORY=https://github.com/OmerFarukOruc/nixos-config.git" in machine.succeed(
    "systemctl show self-deploy.service -p Environment --value"
)
assert "password is required" in machine.execute(f"runuser -u {BOX_USER} -- sudo -n true 2>&1")[1], f"{BOX_USER}'s sudo asks for no password"
machine.succeed("sudo -n true")
machine.succeed("systemd-ac-power")

machine.copy_from_host(deploy_sh, "/tmp/deploy.sh")
machine.wait_until_succeeds(
    f"runuser -u {BOX_USER} -- env XDG_RUNTIME_DIR=/run/user/1003 systemctl --user is-active --quiet other-test.service"
    f" && runuser -u {BOX_USER} -- env XDG_RUNTIME_DIR=/run/user/1003 systemctl --user is-active --quiet herdr-test.service"
)
dp_listed = machine.succeed(
    "fn=$(sed -n '/^session_services() {/,/^}/p' /tmp/deploy.sh);"
    f" runuser -u {BOX_USER} -- bash -c 'on_target() {{ bash -s; }}; eval \"$1\"; session_services' _ \"$fn\" 2>&1"
).split()
print(f"session services: {dp_listed}")
assert "other-test.service" in dp_listed, f"the session check lists no service of {BOX_USER}"
assert "herdr-test.service" not in dp_listed, "the session check does not ignore herdr-*.service"

machine.succeed("nix-env --profile /nix/var/nix/profiles/system --set /run/current-system")

dp_out = {name: machine.succeed(f"readlink -f /run/current-system/specialisation/{name}").strip() for name in dp_systems}
machine.succeed("mkdir -p /var/lib/server-test/flakes")

machine.succeed("install -m 0600 /dev/null /var/lib/server-test/github-token")
machine.succeed("printf ghp_TestToken0123456789 > /var/lib/server-test/github-token")
dp_unit = machine.succeed("systemctl cat self-deploy.service")
assert "LoadCredential=github-token:/var/lib/server-test/github-token" in dp_unit, dp_unit
dp_lib = machine.succeed("systemctl show self-deploy.service -p Environment --value").split("DEPLOY_LIB=")[1].split()[0]
dp_config = machine.succeed(
    "systemd-run --wait --pipe -p RuntimeDirectory=github-config-test -p Environment=PATH=/run/current-system/sw/bin "
    "-p LoadCredential=github-token:/var/lib/server-test/github-token "
    f"bash -c '. {dp_lib}; github_config; stat -c %a \"$RUNTIME_DIRECTORY/nix.conf\" \"$RUNTIME_DIRECTORY/gh/hosts.yml\"; "
    "cut -d= -f1 \"$RUNTIME_DIRECTORY/nix.conf\"; echo \"$NIX_CONFIG\" | cut -d\" \" -f1'"
)
assert dp_config.split() == ["600", "600", "access-tokens", "include"], dp_config
assert "ghp_" not in dp_config
for dp_name, dp_path in dp_out.items():
    dp_flake = textwrap.dedent(
        f"""\
        {{
          outputs = _: {{
            nixosConfigurations.{BOX_HOST}.config.system.build.toplevel =
              builtins.appendContext "{dp_path}" {{ "{dp_path}" = {{ path = true; }}; }};
          }};
        }}
        """
    )
    machine.succeed(f"cat > /var/lib/server-test/flakes/{dp_name}.nix <<'EOF'\n{dp_flake}EOF")

machine.succeed(
    "cat > /var/lib/server-test/flakes/download.nix <<'EOF'\n"
    '{ inputs.dep.url = "https://127.0.0.1:9/dep.tar.gz"; outputs = _: { }; }\n'
    "EOF"
)

machine.succeed(
    "cat > /var/lib/server-test/flakes/throw.nix <<'EOF'\n"
    f'{{ outputs = _: {{ nixosConfigurations.{BOX_HOST}.config.system.build.toplevel = throw "main is broken"; }}; }}\n'
    "EOF"
)

machine.copy_from_host(running_revision_sh, "/tmp/running-revision.sh")
machine.succeed(
    textwrap.dedent(
        """
        cat > /var/lib/server-test/lib.sh <<'EOF'
        export HOME=/root
        main=/var/lib/server-test/main.git
        work=/var/lib/server-test/work
        system() { readlink -f "$1"; }
        records() { ls /root/.local/state/nixos-config-deploy/releases/*.source | wc -l; }
        unit_log() {
          journalctl "_SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value self-deploy.service)" -o cat --no-pager "$@"
        }
        publish() {
          install -m 0644 /var/lib/server-test/flakes/$1.nix "$work/flake.nix"
          git -C "$work" add -A
          git -C "$work" commit -q -m "$1"
          git -C "$work" push -q "$main" HEAD:main
        }
        EOF
        git init -q --bare -b main /var/lib/server-test/main.git
        git init -q -b main /var/lib/server-test/work
        cd /var/lib/server-test/work
        git config user.name test
        git config user.email test@example.invalid
        install -D -m 0755 /tmp/deploy.sh deploy.sh
        install -D -m 0644 /tmp/running-revision.sh scripts/lib/running-revision.sh
        echo '{"nodes":{"root":{}},"root":"root","version":7}' > flake.lock
        """
    )
)


def dp_sh(command):
    return machine.succeed(f". /var/lib/server-test/lib.sh; {command}").strip()


def dp_run(command):
    return machine.execute(f". /var/lib/server-test/lib.sh; {command}")


def dp_deploy():
    """Runs the unit, shows the end of its journal and returns its exit status."""
    status, _ = dp_run("timeout 900 systemctl start self-deploy.service")
    print(f"self-deploy.service ended with status {status}; its journal ends:")
    print(dp_sh("unit_log | tail -n 14 | cut -c1-240 | sed 's/^/  | /'"))
    return status


def dp_system(path):
    return dp_sh(f"system {path}")


print("phase: the booted kernel and initrd run")
machine.succeed("systemctl start self-deploy-reboot.service")
machine.fail("test -e /run/systemd/shutdown/scheduled")
assert "No reboot" in machine.succeed("journalctl -u self-deploy-reboot.service -o cat --no-pager -n 6")

print("phase: a good main")
dp_sh("publish good")
dp_sha = dp_sh('git -C "$work" rev-parse HEAD')
assert dp_deploy() == 0, "the timer's deploy of a good main failed"
assert dp_system("/run/current-system") == dp_out["good"], "the good system does not run"
assert dp_system("/nix/var/nix/profiles/system") == dp_out["good"], "the good system is not the boot default"
dp_record = machine.succeed(
    "bash -c '. /var/lib/server-test/work/scripts/lib/running-revision.sh; running_revision'"
).strip()
print(f"release record of the running system: {dp_record}")
assert dp_record == f"{dp_sha} false switch", "the release record of the running system does not name main"
assert machine.succeed(f"stat -c %U {dp_state}/releases").strip() == "root", "the release records do not belong to root"
machine.fail("systemctl is-active --quiet deploy-rollback.timer")
machine.succeed("findmnt -no FSTYPE /boot | grep -Fx vfat")
print(machine.succeed("ls -R /boot | head -n 30"))
machine.succeed("test -e /boot/EFI/BOOT/BOOTX64.EFI && test -s /boot/limine/limine.conf")
dp_releases = dp_sh("records")

print("phase: the same main again")
assert dp_deploy() == 0, "the second run failed"
assert "already runs" in dp_sh("unit_log"), "the second run does not find the host on main"
assert dp_sh("records") == dp_releases, "the second run left a new release"

print("phase: a main that breaks sshd")
dp_sh("publish broken")
dp_sha = dp_sh('git -C "$work" rev-parse HEAD')
assert dp_deploy() != 0, "the deploy of a broken main succeeded"
assert "Restoring the previous system now" in dp_sh("unit_log"), "the deploy did not roll back"
assert dp_system("/run/current-system") == dp_out["good"], "the good system does not run again"
assert dp_system("/nix/var/nix/profiles/system") == dp_out["good"], "the good system is not the boot default again"
machine.succeed("systemctl is-active --quiet sshd.service")
machine.fail("systemctl is-active --quiet deploy-rollback.timer")
assert "keeps its system until main moves" in dp_sh("unit_log -p err"), "the failure is not in the journal at priority err"
machine.succeed("systemctl is-failed --quiet self-deploy.service")
machine.succeed(f"grep -q '^{dp_sha} ' /var/lib/self-deploy/failed-main")

print("phase: the broken main again")
dp_releases = dp_sh("records")
assert dp_deploy() != 0, "the next run of a broken main succeeded"
assert "failed at" in dp_sh("unit_log -p err"), "the next run does not wait for main to move"
assert "Deploying main at" not in dp_sh("unit_log"), "the next run started a deploy"
assert dp_sh("records") == dp_releases, "the next run left a new release"

print("phase: a main with another initrd")
dp_sh("publish initrd")
assert dp_deploy() == 0, "the deploy of the next main failed"
assert dp_system("/run/current-system") == dp_out["initrd"], "the initrd system does not run"
machine.succeed("test ! -e /var/lib/self-deploy/failed-main")
assert dp_system("/run/booted-system/initrd") != dp_system("/run/current-system/initrd"), "the booted initrd is the running one"
machine.succeed(f"( flock -n 9 && systemctl start self-deploy-reboot.service ) 9>>{dp_state}/deploy.lock")
assert "waits for the next night" in machine.succeed("journalctl -u self-deploy-reboot.service -o cat --no-pager -n 6")
machine.fail("test -e /run/systemd/shutdown/scheduled")
machine.succeed("systemd-run --no-block -p Type=oneshot --unit=nightly-update.service sleep 600")
machine.wait_until_succeeds("systemctl show -p ActiveState --value nightly-update.service | grep -Fx activating")
machine.succeed("systemctl start self-deploy-reboot.service")
dp_waits = machine.succeed("journalctl -u self-deploy-reboot.service -o cat --no-pager | grep -c 'waits for the next night'")
assert dp_waits.strip() == "2", "the reboot did not wait for a running nightly update"
machine.fail("test -e /run/systemd/shutdown/scheduled")
machine.succeed("systemctl stop nightly-update.service")
machine.succeed("systemctl reset-failed nightly-update.service")
machine.succeed("systemctl start self-deploy-reboot.service")
machine.succeed("test -e /run/systemd/shutdown/scheduled")
machine.succeed(f"grep -q '^self-deploy-reboot.service since ' {dp_state}/deploy.owner")
machine.succeed("shutdown -c")
machine.succeed("test ! -e /run/systemd/shutdown/scheduled")

print("phase: a main whose input cannot be downloaded")
dp_releases = dp_sh("records")
dp_sh("publish download")
dp_sha = dp_sh('git -C "$work" rev-parse HEAD')
assert dp_deploy() != 0, "the run succeeded on a main that cannot be evaluated"
assert "could not download an input" in dp_sh("unit_log -p err"), "the failure is not in the journal at priority err"
machine.succeed("test ! -e /var/lib/self-deploy/failed-main")
assert "Deploying main at" not in dp_sh("unit_log"), "the run started a deploy"
assert dp_sh("records") == dp_releases, "the run left a new release"

print("phase: a main whose evaluation fails")
dp_sh("publish throw")
dp_sha = dp_sh('git -C "$work" rev-parse HEAD')
assert dp_deploy() != 0, "the run succeeded on a main that throws"
assert "could not download" not in dp_sh("unit_log"), "an evaluation error was taken for a download error"
machine.succeed(f"grep -q '^{dp_sha} ' /var/lib/self-deploy/failed-main")

dp_sh("publish initrd")
assert dp_deploy() == 0, "the run after the download error failed"
assert "already runs" in dp_sh("unit_log"), "the next run does not find the host on main"
