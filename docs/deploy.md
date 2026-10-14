# Check and deploy a change

- [Check before you deploy](#check-before-you-deploy)
- [Deploy](#deploy)
- [Deploy a merged commit](#deploy-a-merged-commit)
- [What the deploy does](#what-the-deploy-does)
- [Exit codes](#exit-codes)
- [One deploy at a time](#one-deploy-at-a-time)
- [Dirty trees and other checkouts](#dirty-trees-and-other-checkouts)
- [Release records and cleanup](#release-records-and-cleanup)
- [When a deploy fails](#when-a-deploy-fails)

Run deploy commands from fedora-desktop. fedora-desktop has no Nix installed,
so `deploy.sh` builds on the target. The SSH alias of each host in
`~/.ssh/config` selects the target and its SSH key. [CONTEXT.md](../CONTEXT.md)
lists the aliases.

Every deploy command in this guide can change boot or running system state.
Omer's request for a change also approves its deploy. After the change merges
to `main`, run `./deploy.sh <host> switch` for each host it affects without
asking again. A host is affected when its system `drvPath` differs between the
merged change and the `main` it merged onto. Before the merge, print both as
[AGENTS.md](../AGENTS.md#lookups) describes. After the merge,
[Deploy a merged commit](#deploy-a-merged-commit) says how to compare the merge
commit with its parent. When a host is unreachable, report it as the blocker.

This guide uses these terms:

- A **release** is a copy of the files that Git tracks, plus the untracked
  files that Git does not ignore, under
  `~/.local/state/nixos-config-deploy/releases/` on the target. After the
  upload only the build changes it, by adding inputs to its `flake.lock`.
- The **candidate** is the new release that a deploy builds the system from.
  A failed candidate stays on the target for inspection.
- `~/.local/state/nixos-config-deploy/current` is a symlink to the last
  release that deployed successfully. The deploy updates it atomically after
  a successful deploy.
- The **rollback timer** is `deploy-rollback.timer` on the target. When it
  fires, it restores the previous system.

## Check before you deploy

Evaluate the change from this checkout. fedora-desktop has no Nix, so these
scripts copy the working tree to nixos-rog and run Nix there:

```sh
scripts/check-on-rog.sh
scripts/check-on-rog.sh --fix
scripts/eval-on-rog.sh '.#nixosConfigurations.nixos-latitude.config.system.build.toplevel.drvPath'
```

`check-on-rog.sh` runs the formatter check and `nix flake check --no-build`,
and forbids import from derivation, as CI does. With `--fix` it formats first
and copies the changed files back before it checks. `eval-on-rog.sh` evaluates
one attribute and does not forbid import from derivation.

To prove that a package or overlay builds before it lands, run
`scripts/build-on-rog.sh [ATTRIBUTE...]`, because the checks above only
evaluate. It builds each flake attribute in a copy of this checkout on
nixos-rog and prints the output paths. With no attribute it builds nixos-rog's
system, which compiles whatever the caches lack. It creates no result link,
activates nothing, and stops at the first build that fails.

```sh
scripts/build-on-rog.sh '.#nixosConfigurations.nixos-rog.pkgs.deskflow'
```

These checks prove only that evaluation succeeds. The deploy builds the
candidate on the target in step 5 and changes nothing there when the build
fails. The checks do not prove that the hardware and services work after
activation. To read the last deployed source on the target, run
`ssh nixos-latitude 'cd "$(readlink -f ~/.local/state/nixos-config-deploy/current)" && <command>'`.

CI runs the formatter check, `nix flake check --no-build` and the evaluation of
every host on every pull request and on every push to `main`. Its `unit-cycles`
job also runs `ci/unit-cycles.sh`, the ordering-cycle check of step 7, on each
host's units. It builds the unit files without the programs they start, so it
downloads about 1.8 GiB instead of the whole system (CI log, 2026-10-13).

The same CI run evaluates the cached host packages of `ci/cached-packages.nix`,
which the flake outputs do not include. The build-report workflow
(`.github/workflows/build-report.yml`) runs `ci/build-report.sh` on each push
to `main`. It lists in the job summary what each host would compile itself
after a fresh install, because none of its caches holds the build.

Without a `#`, `scripts/eval-on-rog.sh` prints one value of nixos-rog's
configuration; give a flake attribute with `#` for another host. A string
prints raw, and any other value needs `--json`.

Before you deploy a new or changed `script` of a nixos-rog systemd service, run
it with `scripts/run-unit-on-rog.sh`. It runs the script on nixos-rog as root with only
the unit's environment, so a command missing from the unit's `path` fails there
instead of after the deploy. It refuses, with exit 3, a unit that runs as
another user or has no `script`. A unit still running at the timeout passes, as
a long-running unit should.

```sh
scripts/eval-on-rog.sh 'systemd.services."oruc-cpu-limits".environment.PATH'
scripts/run-unit-on-rog.sh oruc-cpu-limits 40
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
When the new system no longer holds some packages, the line before it names
them, as `dix` lists them under REMOVED. The full `dix` comparison comes
earlier, before the activation.

After a deploy to nixos-rog, run `scripts/verify-nixos-rog.sh`. Exit 0 means
that no automated check failed, and the report lists the manual checks for a
person. Exit 1 means that a check failed, and the JSON report names it. By
default the report is a timestamped file under
`~/.local/state/nixos-config-verify/`. For a change you can see on screen,
follow
[Check a visual change](nixos-rog.md#check-a-visual-change).

A deploy that changes the session launcher or an `ORUC_SHELL` condition does
not reach a niri session that is already open. That session started niri
without the new variable, so the shell's services do not start, because their
`ORUC_SHELL` condition fails. The screen stays grey, with no bar or launcher.
To confirm, run
`ssh nixos-rog 'systemctl --user show-environment | grep ORUC_SHELL'`. The line
must read `ORUC_SHELL=<shell>` for the shell that the session runs. No line, or
another shell, means the session predates the change. Log out and back in to fix it. On a grey screen, press Super+Shift+E, then
Enter, to return to the login screen.

## Deploy a merged commit

Deploy a merged change from a detached worktree of its commit, so the deploy
needs no `--allow-dirty`. The main checkout may hold another session's
uncommitted edits, and `--allow-dirty` would ship them. From the main
checkout, run:

```sh
git fetch origin
git worktree add --detach ../nixos-config.worktrees/deploy-<short-sha> <sha>
```

`<sha>` is the output of `gh pr view <n> --json mergeCommit --jq .mergeCommit.oid`,
or `origin/main` after the fetch.

Before you deploy, find the hosts that the commit affects. A squash merge makes
one commit on `main`, so compare the merge commit with its parent `<sha>^`, the
`main` it merged onto. `scripts/eval-on-rog.sh` copies the checkout it lives in,
so evaluate the parent in a detached worktree of its own and the merge commit in
the worktree above:

```sh
git worktree add --detach ../nixos-config.worktrees/base-<short-sha> <sha>^
(cd ../nixos-config.worktrees/base-<short-sha> && scripts/eval-on-rog.sh '.#nixosConfigurations.<host>.config.system.build.toplevel.drvPath')
(cd ../nixos-config.worktrees/deploy-<short-sha> && scripts/eval-on-rog.sh '.#nixosConfigurations.<host>.config.system.build.toplevel.drvPath')
```

A host whose two paths differ is affected, and a host whose paths match needs no
deploy. Run the pair for each host, then remove the `base-<short-sha>` worktree
with `git worktree remove`.

Then run the deploy in the deploy worktree as a background task, with its
output in a log, and with nothing after it:

```sh
cd ../nixos-config.worktrees/deploy-<short-sha> && ./deploy.sh <host> switch > /tmp/deploy-<host>.log 2>&1
```

The task's exit code is then the deploy's exit code. A trailing `echo` or
cleanup command replaces it with its own. Read the log for the
`Deployment completed from release <release>.` line.

The deploy ships everything on that commit, including other sessions' merged
changes. Deploy a commit at or after the one that runs on the host. The running
commit is the `revision=` line of the release record whose `system=` line
matches `readlink -f /run/current-system` on the host (see
[Release records and cleanup](#release-records-and-cleanup)).
`git merge-base --is-ancestor <running> <sha>` exits 0 when your commit is at or
after it. A running release from another checkout that holds files the older commit lacks makes the
deploy exit 78 (see [Dirty trees and other checkouts](#dirty-trees-and-other-checkouts)).

Before you remove the worktree with `git worktree remove`, run
`git status --short` in it. The deploy copies the target's `flake.lock` into
the worktree, and a changed lock is lost with the worktree unless you commit it
on a branch.

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
7. It checks that the candidate's units hold no ordering cycle, which would
   stop the next boot before it reaches its targets (exit 80).
8. For `switch` and `boot`, before it changes the boot default, it checks that
   `/boot` is mounted (exit 79 otherwise).
9. For `switch` and `boot`, it checks the free space on the ESP. The ESP needs
   room for all kernels and initrds of the new generation and its
   specialisations together, plus 1 GiB.
   Without that room, it exits 74 and does not touch the ESP.
10. For `switch` and `test`, when the deploy user is logged in, it records that
    user's running services. The list leaves out:
    - services that a timer, socket or path started
    - apps that a launcher started (`app-*`)
    - `systemd-run` jobs (`run-*`)
    - transient D-Bus services (`dbus-*`)

    When the deploy cannot list the services, it stops before it arms the
    rollback timer.
11. It arms the rollback timer for 420 seconds (exit 71 when it cannot).
12. It activates the candidate with `switch-to-configuration test` in a system
    service, so an SSH drop cannot interrupt the activation.
13. It opens fresh SSH logins and checks that `sshd` and `tailscaled` are
    active.
14. Twenty seconds after the SSH check, it checks the recorded user services.
    The next list says what happens when this check fails.
15. It stops the rollback timer.
16. For `switch`, it makes the checked build the system profile and boot
    default. It does not build or activate the build again.
17. After the whole deploy succeeds, it updates `current` and copies the
    target's `flake.lock` into this repository. Then it prints
    `Deployment completed from release <release>.`

A host that deploys itself (the host name given is its own) runs every step
locally. It checks the two units without an SSH login.

When a step after the build fails, the deploy acts as follows:

- **A user service fails the step 14 check.** One of them failed or waits to
  restart, or the deploy cannot query them. The deploy restores the previous
  system at once and exits 75. This check catches a switch that breaks the
  desktop shell or compositor while SSH still answers. It does not catch a
  service that its `ORUC_SHELL` condition keeps from starting; see the
  grey-screen paragraph under [Deploy](#deploy).
- **Activation fails.** The deploy restores the previous system at once. A
  unit that fails during activation (`switch-to-configuration` exit 4) counts
  as a failed activation.
- **The SSH connection drops during activation.** The deploy reconnects and
  polls for the exit status that the activation unit records in
  `/run/deploy-activate.status`, until 180 seconds after it started the
  activation. It restores the previous system at once when the status is not 0
  or the unit ended without one. When no status arrives in time, the deploy
  exits 1 and the rollback timer restores the previous system, at most 420
  seconds after the deploy armed it.
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
and the running user services. It does not roll back a program that starts but
misbehaves.

## Exit codes

The table lists every code from 64 to 99 that `deploy.sh` and the updater set.
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
| 73 | Installing the boot entries failed. | System profile and boot entries set back to the previous generation. After `switch`, the candidate still runs and no rollback timer is armed. |
| 74 | The ESP lacks room for the new kernels and initrds plus 1 GiB. | ESP untouched. |
| 75 | A recorded user service failed, waits to restart, or could not be queried. | Previous system restored. |
| 76 | Another host no longer evaluates. The [updater](nixos-rog.md#hourly-updater) sets this status, not `deploy.sh`, and then exits 1. | Not deployed. |
| 77 | Another deploy holds the lock on the host. | Unchanged. |
| 78 | A running or boot-default release holds files that this checkout lacks. | Unchanged. |
| 79 | `/boot` is not mounted. | Unchanged. |
| 80 | The candidate's units hold an ordering cycle, so the next boot would not finish. | Unchanged. |

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
drop. A squash-merged branch passes when the version it deployed is the version
that merged, because the merge puts that version in `main`'s history. The
check compares the candidate files first and reads Git history only for files
that differ.

A system with no release record, such as one built by hand, is reported and not
checked. `--replace` skips the check.

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
- the start time
- `CLAUDE_CONFIG_DIR`, when an agent deployed it

When the deploy promotes the release, it adds the system it built as a
`system=` line. To see who deployed what a host runs, read the record whose
`system=` line matches `readlink -f /run/current-system`.

A release that built also has `<release>.blobs` beside its record. It lists
the Git blob of every uploaded file, and the deploy uses it to find files that
a new deploy would drop.

Release cleanup is explicit. This command deletes old releases:

```sh
./deploy.sh nixos-latitude prune
```

The command keeps the five newest releases. It always keeps the release
that `current` selects, and the releases whose records match the running
system or the boot default. It prints every older release it will delete.
Then it deletes those releases with their records and `.blobs` files.

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
3. Run `scripts/check-on-rog.sh` again.
4. Run the same deploy command again. For example, rerun the `test` action,
   which does not persist:

   ```sh
   ./deploy.sh nixos-latitude test
   ```

   The deploy prints `Deployment completed from release <release>.`
