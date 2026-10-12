# Check and deploy a change

- [Check before you deploy](#check-before-you-deploy)
- [Deploy](#deploy)
- [What the deploy does](#what-the-deploy-does)
- [Exit codes](#exit-codes)
- [One deploy at a time](#one-deploy-at-a-time)
- [Dirty trees and other checkouts](#dirty-trees-and-other-checkouts)
- [Release records and cleanup](#release-records-and-cleanup)
- [When a deploy fails](#when-a-deploy-fails)

Run deploy commands from fedora-desktop. fedora-desktop has no Nix installed,
so `deploy.sh` builds on the target. The SSH alias `nixos-latitude` in
`~/.ssh/config` selects the target and its SSH key.

Every deploy command in this guide can change boot or running system state.
Omer's request for a change also approves its deploy. After the change merges
to `main`, run `./deploy.sh <host> switch` for each host it affects without
asking again. When a host is unreachable, report it as the blocker.

This guide uses these terms:

- A **release** is a copy of the source-controlled files under
  `~/.local/state/nixos-config-deploy/releases/` on the target. The deploy
  never changes a release after it writes it.
- The **candidate** is the new release that a deploy builds the system from.
  A failed candidate stays on the target for inspection.
- `~/.local/state/nixos-config-deploy/current` is a symlink to the last
  release that deployed successfully. The deploy updates it atomically after
  a successful deploy.
- The **rollback timer** is `deploy-rollback.timer` on the target. When it
  fires, it restores the previous system.

## Check before you deploy

These commands check evaluation and build the system on the target. They do
not activate it:

```sh
ssh nixos-latitude 'cd "$(readlink -f ~/.local/state/nixos-config-deploy/current)" && nix eval --raw --no-write-lock-file .#nixosConfigurations.nixos-latitude.config.system.build.toplevel.drvPath'
ssh nixos-latitude 'cd "$(readlink -f ~/.local/state/nixos-config-deploy/current)" && nix flake check --no-build --no-write-lock-file'
ssh nixos-latitude 'cd "$(readlink -f ~/.local/state/nixos-config-deploy/current)" && nix build --no-link --no-write-lock-file .#nixosConfigurations.nixos-latitude.config.system.build.toplevel'
```

The commands use the source that the `current` symlink selects. They prove
only that evaluation or the build succeeds. They do not activate the
generation, and they do not prove that the hardware and services work after
activation.

CI runs the formatter check, `nix flake check --no-build` and the evaluation of
every host on every pull request and on every push to `main`.

fedora-desktop has no Nix, so `scripts/check-on-rog.sh` runs the formatter
check and `nix flake check --no-build` on a copy of this checkout on nixos-rog.
With `--fix` it formats instead of checking and copies the changed files back:

```sh
scripts/check-on-rog.sh
scripts/check-on-rog.sh --fix
```

## Deploy

`switch` is the default action. It activates the generation now and makes it
the boot default:

```sh
./deploy.sh nixos-latitude
```

`test` activates the generation until reboot and does not change the boot
default. `boot` sets the boot default and does not activate the running
system:

```sh
./deploy.sh nixos-latitude test
./deploy.sh nixos-latitude boot
```

A successful deploy ends with the line `Deployment completed from release <release>.`

## What the deploy does

`switch` and `test` activate the candidate, check it, and roll back when a
check fails. `boot` builds the same way, then makes the build the system
profile and boot default. It activates nothing and has no rollback timer.

The deploy runs these steps in order:

1. It takes the deploy lock on the host. See
   [One deploy at a time](#one-deploy-at-a-time).
2. Before it uploads anything, it checks the running release and the
   boot-default release. See [Dirty trees and other checkouts](#dirty-trees-and-other-checkouts).
3. It copies the source-controlled files to a new release, the candidate.
4. It stops before it changes anything when a rollback timer from an earlier
   run is still pending (exit 70).
5. It builds the candidate on the target. When the build fails, nothing on the
   target changes.
6. It prints dix's comparison of the running and the new system. A failed
   comparison does not stop the deploy.
7. Before it changes the boot default, it checks that `/boot` is mounted
   (exit 79 otherwise).
8. It checks the free space on the ESP. The ESP needs room for all kernels and
   initrds of the new generation and its specialisations together, plus 1 GiB.
   Without that room, it exits 74 and does not touch the ESP.
9. For `switch` and `test`, when the deploy user is logged in, it records that
   user's running services. The list leaves out:
   - services that a timer, socket or path started
   - apps that a launcher started (`app-*`)
   - `systemd-run` jobs (`run-*`)
   - transient D-Bus services (`dbus-*`)

   When the deploy cannot list the services, it stops before it arms the
   rollback timer.
10. It arms the rollback timer for 420 seconds (exit 71 when it cannot).
11. It activates the candidate with `switch-to-configuration test` in a system
    service, so an SSH drop cannot interrupt the activation.
12. It opens fresh SSH logins and checks that `sshd` and `tailscaled` are
    active.
13. Twenty seconds after the SSH check, it checks the recorded user services.
    The next list says what happens when this check fails.
14. It stops the rollback timer.
15. For `switch`, it makes the checked build the system profile and boot
    default. It does not build or activate the build again.
16. After the whole deploy succeeds, it updates `current` and copies the
    target's `flake.lock` into this repository. Then it prints
    `Deployment completed from release <release>.`

A host that deploys itself (the host name given is its own) runs every step
locally. It checks the two units without an SSH login.

When a step after the build fails, the deploy acts as follows:

- **A user service fails the step 13 check.** One of them failed or waits to
  restart, or the deploy cannot query them. The deploy restores the previous
  system at once and exits 75. This check catches a switch that breaks the
  desktop shell or compositor while SSH still answers.
- **Activation fails.** The deploy restores the previous system at once. A
  unit that fails during activation (`switch-to-configuration` exit 4) counts
  as a failed activation.
- **The SSH connection drops during activation.** The deploy reconnects and
  waits up to 180 seconds for the exit status that the activation unit records
  in `/run/deploy-activate.status`. It restores the previous system when that
  status is not 0.
- **The restore fails.** The deploy prints that the target may still run the
  candidate. It leaves the rollback timer armed, and the timer repeats the
  restore at its deadline. The boot default did not change, so a reboot also
  restores the previous system.
- **The target stops answering.** The rollback timer restores the previous
  system after 420 seconds. It needs no command from the machine that runs the
  deploy.
- **Installing the boot entries fails.** The deploy sets the system profile and
  boot entries back to the previous generation and exits 73.

For `switch`, the candidate becomes the boot default only after it passes the
SSH check and the user-service check.

The deploy checks only what it can see: the build, activation, SSH, Tailscale
and the running user services. A program that starts but misbehaves
stays installed.

## Exit codes

The table lists every code from 64 up that `deploy.sh` and the updater set.
`nix fmt` runs `scripts/check-exit-codes.sh`, which fails when the table and the
scripts differ. A failed activation returns the exit status of
`switch-to-configuration`, such as 4. Other failures exit with other codes,
such as 1.

| Code | Cause | State of the target |
| --- | --- | --- |
| 64 | The command line is wrong: an unknown option, a wrong number of arguments, an invalid host name or an invalid action. | Unchanged. |
| 65 | The Git tree is dirty, and the command has no `--allow-dirty`. | Unchanged. |
| 70 | A rollback timer from an earlier deploy is still pending. | Unchanged. |
| 71 | The deploy could not arm the rollback timer. | Nothing activated. |
| 72 | The rollback ran before the deploy stopped the rollback timer, so the target is not on the candidate. | Previous system restored by the rollback timer. |
| 73 | Installing the boot entries failed. | System profile and boot entries set back to the previous generation. |
| 74 | The ESP lacks room for the new kernels and initrds plus 1 GiB. | ESP untouched. |
| 75 | A recorded user service failed, waits to restart, or could not be queried. | Previous system restored. |
| 76 | Another host no longer evaluates. The [updater](nixos-rog.md#hourly-updater) sets this status, not `deploy.sh`, and then exits 1. | Not deployed. |
| 77 | Another deploy holds the lock on the host. | Unchanged. |
| 78 | A running or boot-default release holds files that this checkout lacks. | Unchanged. |
| 79 | `/boot` is not mounted. | Unchanged. |

## One deploy at a time

Only one deploy runs on a host at a time. A second deploy exits 77 and names
the deploy that holds the lock.

The lock goes when that deploy exits or loses its connection. Keepalives on
both ends close a dead connection within about 45 seconds.

When a deploy finds its own lock dropped before activation, it does these
steps:

1. It takes the lock again.
2. It repeats the release check in
   [Dirty trees and other checkouts](#dirty-trees-and-other-checkouts).
3. It reads the running system again for the rollback.

It exits 77 if another deploy holds the lock by then, or 70 if another deploy
left a rollback timer. During activation, the pending rollback timer keeps
other deploys out.

## Dirty trees and other checkouts

The deploy refuses a dirty Git tree. When that state is intentional, first
review every local change. Then use the single escape hatch for a dirty
deploy:

```sh
./deploy.sh --allow-dirty nixos-latitude test
```

A dirty deploy includes modified tracked files and untracked files that Git
does not ignore. The deploy never copies ignored files.

Before it uploads anything, the deploy checks two releases on the host. One is
the release that runs, and one is the release that is the boot default. The
deploy exits 78 when one of them meets both of these conditions:

- It came from another checkout.
- It holds a version of a file that is neither in the candidate nor anywhere
  in this checkout's history.

The deploy then prints that release's record and the files the deploy would
drop. A squash-merged branch passes, because each version it deployed is in
`main`'s history.

To continue, merge the work into this checkout. Or, after the owner of that
work agrees, rerun with `--replace`:

```sh
./deploy.sh --replace nixos-rog test
```

## Release records and cleanup

Each release has a record beside it,
`~/.local/state/nixos-config-deploy/releases/<release>.source`. The record
names these facts:

- the machine and checkout the release came from
- the branch and the commit
- whether the tree was dirty
- the action
- `CLAUDE_CONFIG_DIR`, when an agent deployed it

When the deploy promotes the release, it adds the system it built as a
`system=` line. To see who deployed what a host runs, read the record whose
`system=` line matches `readlink -f /run/current-system`.

Release cleanup is explicit. This command deletes old releases:

```sh
./deploy.sh nixos-latitude prune
```

The command keeps the five newest releases. It always keeps the release
that `current` selects, and the releases whose records match the running
system or the boot default. It prints every older release it will delete.
Then it deletes those disposable source copies and their records.

## When a deploy fails

When the rebuild, the activation or a check after the upload fails, the failed
release stays on the target. The local `flake.lock` does not change. A build that
succeeds and then rolls back changes nothing locally. The `current` symlink
still points to the last successful release.

After a successful deploy changes `flake.lock`, commit that change before the
next clean deploy.

When a rebuild fails, do these steps:

1. Read the complete output of the rebuild. The failure message names the
   candidate release that stays on the target for read-only investigation.
2. Fix the source on fedora-desktop. When you also try a fix with a rebuild on
   the target, apply the same fix here.
3. Run the evaluation and build commands in
   [Check before you deploy](#check-before-you-deploy) again.
4. Run the same deploy command again. For example, rerun the `test` action,
   which does not persist:

   ```sh
   ./deploy.sh nixos-latitude test
   ```

   The deploy prints `Deployment completed from release <release>.`
