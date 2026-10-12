# Check and deploy a change

Run deploy commands from fedora-desktop. The script copies source-controlled files
to a fresh release under `~/.local/state/nixos-config-deploy/releases/` and builds
the system from that immutable candidate on the target. After a successful deploy, it
atomically updates `~/.local/state/nixos-config-deploy/current`. Failed candidates
remain available for inspection, and earlier releases are never modified.
fedora-desktop has no Nix installed. The SSH alias `nixos-latitude` in
`~/.ssh/config` selects the target and its SSH key.

Check evaluation and build the system on the target without activating it:

```sh
ssh nixos-latitude 'cd "$(readlink -f ~/.local/state/nixos-config-deploy/current)" && nix eval --raw --no-write-lock-file .#nixosConfigurations.nixos-latitude.config.system.build.toplevel.drvPath'
ssh nixos-latitude 'cd "$(readlink -f ~/.local/state/nixos-config-deploy/current)" && nix flake check --no-build --no-write-lock-file'
ssh nixos-latitude 'cd "$(readlink -f ~/.local/state/nixos-config-deploy/current)" && nix build --no-link --no-write-lock-file .#nixosConfigurations.nixos-latitude.config.system.build.toplevel'
```

These checks use the source selected by the `current` symlink. They prove
evaluation or build success only. They do not activate the generation or prove
that the hardware and services work after activation.

CI runs the formatter check, `nix flake check --no-build` and the evaluation of every
host on every pull request and on every push to `main`. To format locally, run
`ssh nixos-rog 'cd <copy of the repo> && nix fmt'`, because fedora-desktop has no
Nix, then copy the changed files back.

Every deploy command below can change boot or running system state. Run one only
after activation is separately authorized. `switch` is the default. It activates
the generation now and makes it the boot default:

```sh
./deploy.sh nixos-latitude
```

Use `test` to activate until reboot without changing the boot default, or `boot`
to set the boot default without activating the running system:

```sh
./deploy.sh nixos-latitude test
./deploy.sh nixos-latitude boot
```

`switch` and `test` confirm or roll back. The script builds the candidate on the
target first and changes nothing if the build fails. It then arms a 420 second
timer (`deploy-rollback.timer`) that restores the previous system, and activates
the candidate with `switch-to-configuration test` in a system service, so an SSH
drop cannot interrupt it. The script then opens fresh SSH logins and checks that
`sshd` and `tailscaled` are active. A host that deploys itself (the host name
given is its own) runs every step locally and checks the two units without an
SSH login. When the deploy user is logged in, the script also records that
user's running services before activation, except those a timer, socket or path
started, apps a launcher started (`app-*`), `systemd-run` jobs (`run-*`) and
transient D-Bus services (`dbus-*`). The script stops before it arms the timer
when it cannot list them. Twenty seconds after the SSH
check, if one of them has failed or waits to restart, or the script cannot query
them, it restores the previous system at once and exits 75. This catches a switch that breaks the
desktop shell or compositor while SSH still answers. Only after that does it stop the timer, and
for `switch` it makes the confirmed build the system profile and boot default
without building or activating it again. If activation fails, the
script restores the previous system at once. A unit that fails during activation
(`switch-to-configuration` exit 4) counts as a failed activation. When the SSH
connection drops during activation, the script reconnects and waits up to 180
seconds for the exit status that the activation unit records in
`/run/deploy-activate.status`, and restores the previous system when it is not 0.
When the restore fails, the script prints that the target may still run the
candidate and leaves the timer armed, which repeats the restore at its deadline.
The boot default is unchanged then, so a reboot also restores the previous system. If the target
stops answering, the timer restores the previous system after 420 seconds,
without any command from this machine. A candidate that is never confirmed never
becomes the boot default.
After the build, the script prints dix's comparison of the running and the new
system; a failed comparison does not stop the deploy.
Before it changes the boot default, the script checks that `/boot` is mounted
(exit 79 otherwise) and that the ESP has room for
every kernel and initrd of the new generation and its specialisations plus 1 GiB,
and exits 74 without touching the ESP when it does not. If installing the boot
entries fails, it sets the system profile and boot entries back to the previous
generation and exits 73.
`boot` builds the same way, then makes the build the system profile and boot
default. It activates nothing and has no timer. A pending `deploy-rollback.timer` from
an earlier run makes the next deploy stop before it changes anything.

The script refuses a dirty Git tree. After reviewing every local change, use the
single dirty-deploy escape hatch when that state is intentional:

```sh
./deploy.sh --allow-dirty nixos-latitude test
```

The dirty deploy includes modified tracked files and non-ignored untracked files.
Ignored files are never copied.

Each release has a record beside it,
`~/.local/state/nixos-config-deploy/releases/<release>.source`. The record names
the machine and checkout it came from, the branch, the commit, whether the tree
was dirty, the action, and `CLAUDE_CONFIG_DIR` when an agent deployed it.
Promotion adds the system it built. To see who deployed what a host runs, read
the record whose `system=` line matches `readlink -f /run/current-system`.

Only one deploy runs on a host at a time. A second deploy exits 77 and names the
deploy that holds the lock. The lock goes when that deploy exits or loses its
connection. Keepalives on both ends close a dead connection within about 45
seconds. When a deploy finds its own lock dropped before activation, it takes the
lock again and repeats the check below, reads the running system again for the
rollback, and exits 77 if another deploy holds it by then or 70 if it left a
rollback timer. During activation the pending rollback timer keeps other deploys out.

Before it uploads anything, the script checks the release that runs on the host
and the release that is its boot default. When one of them came from another
checkout and holds a version of a file that is neither in the candidate nor
anywhere in this checkout's history, the script exits 78. It prints that
release's record and the files the deploy would drop. A squash-merged branch
passes, because each version it deployed is in `main`'s history. Merge the work
into this checkout, or rerun with `--replace` after its owner agrees:

```sh
./deploy.sh --replace nixos-rog test
```

When the target check, the rebuild or the activation fails, the failed release
stays on the target and the local `flake.lock` stays unchanged. The script copies
the target's `flake.lock` back into this repository only after the whole deploy
succeeds. A build that succeeds and then rolls back changes nothing locally.
Commit the lock change before the next clean deployment.

The deploy checks only what it can see: the build, activation, SSH, Tailscale
and the running user services. A program that starts but misbehaves stays
installed.

Release cleanup is explicit. The command below keeps the five newest candidates,
always protects the release selected by `current` and the releases whose records
match the running system or the boot default, prints every older release it will
delete, and then removes those disposable source copies with their records:

```sh
./deploy.sh nixos-latitude prune
```

If a rebuild fails, inspect its complete output, fix the source on
fedora-desktop, and rerun the chosen deploy command. The failure message names
the candidate release retained for read-only investigation. The `current`
symlink continues to identify the last successful release. Do not run a
different target-side rebuild and then forget to apply the same fix here.

For example, re-run the evaluation and build commands above, then retry the same
non-persistent test action after the fix is authorized:

```sh
./deploy.sh nixos-latitude test
```
