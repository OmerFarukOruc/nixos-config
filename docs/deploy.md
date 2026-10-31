# Check and deploy a change

- [Check before you deploy](#check-before-you-deploy)
- [Deploy](#deploy)
- [Deploy a change on main](#deploy-a-change-on-main)
- [Upgrade a host to main](#upgrade-a-host-to-main)
- [Self-deploy of a server](#self-deploy-of-a-server)
- [What the deploy does](#what-the-deploy-does)
- [Exit codes](#exit-codes)
- [One deploy at a time](#one-deploy-at-a-time)
- [Dirty trees and other checkouts](#dirty-trees-and-other-checkouts)
- [Release records and cleanup](#release-records-and-cleanup)
- [When a deploy fails](#when-a-deploy-fails)

Run deploy commands from nixos-desktop or nixos-rog. `deploy.sh` builds on the
target; a deploy of a host from that host runs locally. The SSH alias of each
host in `~/.ssh/config` selects the target and its SSH key. [CONTEXT.md](../CONTEXT.md)
lists the aliases. A server is the exception, because its deploys log in as
root ([Self-deploy of a server](#self-deploy-of-a-server)).

Every deploy command in this guide can change boot or running system state.
Omer's request for a change also approves its deploy. After the change reaches
`main`, run `./deploy.sh <host> switch` for each host it affects without
asking again. A host is affected when its system `drvPath` differs between the
pushed change and the `main` it landed on. Before the push, print both as
[AGENTS.md](../AGENTS.md#lookups) describes. After the push,
`scripts/affected-hosts.sh <old>..<sha>` compares the two
([Deploy a change on main](#deploy-a-change-on-main)). When a host is unreachable,
read its line in `tailscale status`. A line without `offline`, or with
`offline, last seen` under about 6 minutes ago, can be a short outage: on
2026-09-21 nixos-latitude lost its Wi-Fi for about 6 minutes
([nixos-latitude.md](nixos-latitude.md#operation)). Retry the deploy once
after about 6 minutes, and report the host as the blocker only when it is
still unreachable. A host offline for longer, such as one that is powered off,
gets no retry; report that it still runs an older system.
`scripts/affected-hosts.sh --running` lists each host whose running system
differs from `main`, such as one that was offline at the last deploy, so run it
before you end a session that deployed. For a host that is behind, it lists the
commits the host lacks; a host behind only by another session's pushes is that
session's to deploy.

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

A change reaches `main` only through the git hooks of `devenv.nix`, which
direnv installs when it loads the devenv shell. GitHub runs no check of a
commit that a person pushes.

| Hook | Runs | Took on nixos-rog |
| --- | --- | --- |
| pre-commit | `nix fmt`; a file it rewrites stops the commit until a second `git add` | under 2 s of formatting, as treefmt reports it |
| pre-push | `ci/checks.sh` and `ci/unit-cycles.sh` on the staged tree, under `heavy` where it exists | 190 to 224 s with a warm store in 3 runs (2026-10-23) |

The times come from a test clone on 2026-10-23. The same checks run with one
command, and `devenv tasks run ci` also builds every host's system with
`ci/build-hosts.sh`. `ci/build-hosts.sh --roots DIR` keeps each system as a
link in `DIR`, which Nix's garbage collection leaves alone:

```sh
devenv test
devenv tasks run ci
```

The hooks see the staged tree, because prek sets unstaged edits aside while a
hook runs. The checked tree is the pushed one only when you committed
everything staged and the push sends `HEAD`, so commit everything before you
push. No hook builds a host's system. The deploy builds it on the target
and changes nothing when the build fails, so a commit that does not build for
another host fails only at that host's next deploy. `devenv tasks run ci`
builds them all before a push.

The gate exists only where the devenv shell loaded. Every host installs
devenv, and direnv fails in a checkout where it is missing. A clone that never
ran `direnv allow` has no hooks, and on nixos-rog and nixos-desktop `heavy`
fails without a user session bus, which fails the push hook. Git opens the SSH
connection to GitHub before the pre-push hook runs and holds it open, and GitHub
closes it when it stays idle. A push whose hook took 420 s failed without
keepalives and passed with them (2026-10-23). So `home-manager/modules/git.nix`
sets `core.sshCommand` to `ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=10`.
Ten missed keepalives, 300 s, end the connection, which is more than the 190 to
224 s that the pre-push checks took on nixos-rog.

A worktree gets the hooks from the shared `.git/hooks`, but their config is a
link that the devenv shell writes. Until `direnv allow <worktree>` and a first
`direnv exec <worktree> true` have run there, a commit in it fails with
`config file not found: .pre-commit-config.yaml`. Commit from a worktree only
after that step; `PREK_ALLOW_NO_CONFIG=1` skips the hooks and with them every
check.

To check without a loaded shell, these scripts copy the working tree to `/tmp`
on the host that runs them and run Nix there, under `heavy` where the host has
it:

```sh
scripts/check.sh
scripts/check.sh --fix
scripts/eval.sh '.#nixosConfigurations.nixos-latitude.config.system.build.toplevel.drvPath'
```

`check.sh` runs `ci/checks.sh`, the checks of the pre-push hook, with
import from derivation forbidden. With `--fix` it formats first
and copies the changed files back before it checks. `eval.sh` evaluates
one attribute and does not forbid import from derivation.

To prove that a package or overlay builds before it lands, run
`scripts/build.sh [ATTRIBUTE...]`, because the checks above only
evaluate. It builds each flake attribute in a copy of this checkout and prints
the output paths. A package that modules load with `pkgs.callPackage
../../pkgs/NAME.nix { }` has no flake attribute, so pass its file instead, such
as `pkgs/claude-tools.nix`; the script builds it with nixos-rog's
`pkgs.callPackage` and no extra arguments. With no attribute it builds nixos-rog's
system, which compiles whatever the caches lack. It creates no result link,
activates nothing, and stops at the first build that fails.

```sh
scripts/build.sh '.#nixosConfigurations.nixos-rog.pkgs.deskflow'
```

These checks prove only that evaluation succeeds. The deploy builds the
candidate on the target in step 5 and changes nothing there when the build
fails. The checks do not prove that the hardware and services work after
activation. To read the last deployed source on the target, run
`ssh nixos-latitude 'cd "$(readlink -f ~/.local/state/nixos-config-deploy/current)" && <command>'`.

`ci/checks.sh` validates the flake's output kinds and formatter, then checks each
host's system derivation type and `drvPath` in a separate process. It also
evaluates a workstation with the box browser forced on (`ci/box-browser.nix`),
to check the display's command line, and a bare server record (`ci/server.nix`),
to check what the schema accepts and rejects.
`ci/unit-cycles.sh` runs the ordering-cycle check
of step 7 on each host's units. It builds the unit files without the programs
they start, so it downloaded about 1.8 GiB instead of the whole system on a
GitHub runner on 2026-10-13.

Without a `#`, `scripts/eval.sh` prints one value of nixos-rog's
configuration; give a flake attribute with `#` for another host. A string
prints raw, and any other value needs `--json`.

Before you deploy a new or changed `script` of a nixos-rog systemd service, run
it with `scripts/run-unit-on-rog.sh`. It builds and runs the script on nixos-rog
as root with only the unit's environment, so a command missing from the unit's `path` fails there
instead of after the deploy. It refuses, with exit 3, a unit that runs as
another user or has no `script`. A unit still running at the timeout passes, as
a long-running unit should.

For a new or changed Home Manager user unit, such as `oled-care`, add `--user`.
It runs the unit as built, ExecStartPre, conditions and environment included,
in oruc's user manager under another name, and prints its journal. The copy
runs beside the real unit when that runs, so a daemon such as `airpods-tui`
may meet its own running instance. A oneshot unit still running at the
timeout fails, and so does a unit whose condition was not met.

```sh
scripts/eval.sh 'systemd.services."oruc-cpu-limits".environment.PATH'
scripts/run-unit-on-rog.sh oruc-cpu-limits 40
scripts/run-unit-on-rog.sh --user oled-care
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
This check is for a niri desktop with more than one shell. nixos-rog is that
host. nixos-latitude has one niri shell, so it does not set `ORUC_SHELL`.
To confirm on the host you deployed, run
`ssh <host> 'systemctl --user show-environment | grep ORUC_SHELL'`. The line
must read `ORUC_SHELL=<shell>` for the shell that the session runs. No line, or
another shell, means the session predates the change. Log out and back in to fix it. On a grey screen, press Super+Shift+E, then
Enter, to return to the login screen.

## Deploy a change on main

Deploy a pushed change from a detached worktree of its commit, so the deploy
needs no `--allow-dirty`. The main checkout may hold another session's
uncommitted edits, and `--allow-dirty` would ship them.

First find the hosts that the push affects. A push can carry several commits,
so the script compares the system `drvPath` of every host at the pushed commit
`<sha>` with the one at `<old>`, the `main` the push landed on. The host that
runs it evaluates both from GitHub, so this step needs no worktree. It runs
one `nix eval` per host, under `heavy` where the host has it, because `heavy`
(`home-manager/modules/heavy.nix`) caps the memory of each evaluation. One
evaluation per host stays under that cap. Three systems in one evaluation did
not, and systemd-oomd killed it. nixos-rog
took 70 to 90 seconds (measured on 2026-10-15), and nixos-desktop about 160
seconds for one revision (2026-10-24). The host that runs the script keeps
each commit's result in `${XDG_CACHE_HOME:-~/.cache}/nixos-config/affected-hosts/`,
so the `--running` check after the deploy, and the next push's comparison with
this commit, skip that evaluation when they run on the same host. From the main
checkout, run:

```sh
git fetch origin
scripts/affected-hosts.sh <old>..<sha>
```

`<old>` is the `origin/main` you rebased onto before the push, and `<sha>` the
commit you pushed. With one commit, `scripts/affected-hosts.sh <sha>` compares
it with its parent.

Deploy each host that it prints as `affected`. A host it prints as `unchanged`
or `not-deployed` needs no deploy; `not-deployed` is a host whose record in
`machines/inventory.nix` sets `deployed = false`; no host sets it now.

nixos-rog and devbox deploy `main` themselves every 2 hours, through
the [deploy unit](nixos-rog.md#deploy-unit) and
[self-deploy](#self-deploy-of-a-server). Leave an affected one to its timer,
and deploy it by hand only when the change needs proof on that host now, such
as a new systemd unit or a change on screen. A hand deploy and a timer deploy
take the same lock, so the one that starts second exits 77
([One deploy at a time](#one-deploy-at-a-time)).
nixos-desktop and nixos-latitude have no timer, so deploy each affected one.

For each affected host, run this block from the main checkout as one
background task, with nothing after it. It makes the deploy worktree unless it
exists, prints the path of a new log as its only output, and deploys with its
output in that log:

```sh
d=$HOME/Desktop/workspace/worktrees/nixos-config/deploy-<short-sha>
[ -d "$d" ] || git worktree add -q --detach "$d" <sha>
log=$(mktemp /tmp/deploy-<host>.XXXXXX) && echo "$log" && cd "$d" && { ./deploy.sh <host> switch > "$log" 2>&1; rc=$?; echo "exit $rc" >> "$log"; exit $rc; }
```

Each run gets its own log, because two agents can deploy the same commit to
the same host, and the second one exits 77 (see
[One deploy at a time](#one-deploy-at-a-time)). The task's exit code is the
deploy's exit code; a command after the block would replace it with its own.
The log's last line is `exit <code>` however the deploy ends, so
`wait-exit <log> <seconds>` ends on it. On success, the line before it
is `Deployment completed from release <release>.`.

The deploy ships everything on that commit, including other sessions' pushed
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

## Upgrade a host to main

Run `upgrade` on a host to bring that host to the newest `main`. On nixos-rog
and nixos-desktop it runs the [deploy unit](nixos-rog.md#deploy-unit) now, and on a host that
runs [self-deploy](#self-deploy-of-a-server) it starts that unit. On every other
host it deploys `main` to that host in these steps:

1. It clones this repository over https into
   `~/.local/state/nixos-config-upgrade` when the clone is missing. It then
   fetches `main` and resets the clone to it, which drops any change in the
   clone, so keep no work there.
2. When the host runs a clean release whose files match that commit, it prints
   `<host> already runs main at <commit>.` with the first 12 characters of
   the commit, and exits 0. A `test` deploy does not count, because it leaves
   the boot default behind.
3. Otherwise it runs `./deploy.sh <host> switch` in the clone, so from there
   its output and [exit codes](#exit-codes) are those of `deploy.sh`. After
   exit 78 it adds what to do instead of changing the clone.

Before `deploy.sh` starts, `upgrade` exits 2 for any arguments other than
one `--replace`, 1 when it runs as root, and with Git's status when the clone or
fetch fails.

`upgrade` runs as your own user, because the releases live in that user's
home. It never moves an input; inputs move in the nightly update on devbox
([Nightly update](devbox.md#nightly-update)) or an update by hand
([Update by hand](updates.md#update-by-hand)). After exit 78, merge the work of the running release into
`main`, or run `upgrade --replace` once its owner agrees that the deploy may
drop its files ([Dirty trees and other checkouts](#dirty-trees-and-other-checkouts)).

`nixos-rebuild` on every host refuses every action except `switch`, `boot` or
`test` with `--rollback`, `list-generations` and `--help`, and points to
`upgrade` (`nixosModules/upgrade.nix`). A plain `sudo nixos-rebuild switch` once built
the stale install copy in `/etc/nixos` on nixos-desktop and switched to it,
which removed users and services until a deploy of `main` brought them back.

## Self-deploy of a server

A server deploys itself, so it follows `main` without anyone at a keyboard. The
host sets `oruc.deploy.self.enable`, and `nixosModules/deploy-host.nix` then
adds two timers. It does not use `system.autoUpgrade`, which would skip the
deploy lock and the rollback when sshd or tailscaled break. No NixOS option or
upstream module runs `deploy.sh` from a timer, so the module builds the unit
itself.

**The deploy timer.** `self-deploy.timer` starts `self-deploy.service` at minute
30 of every even hour, with up to 10 minutes of random delay. The calendar is in
UTC, because `nixosModules/common.nix` sets the timezone to Europe/Istanbul.
Every 2 hours matches nixos-rog's deploy unit
([Deploy unit](nixos-rog.md#deploy-unit)), so `main` reaches the server within
2 hours and 10 minutes of a push. The even hours at minute 30 keep a run clear of the
02:10 UTC reboot. A run that finds nothing to deploy costs one `git fetch` and
one evaluation. The service runs `scripts/self-deploy.sh` as root. The unit is
the one that nixos-rog's deploy unit uses (`nixosModules/deploy-unit.nix`, from
`nixosModules/auto-update.nix`), and the clone and deploy steps are in
`scripts/lib/pull-main.sh`. The script only deploys; it moves no input.
nixos-rog's `scripts/pull-main.sh` is its twin. A failure here is the unit's own
status and a line at priority err, where nixos-rog shows a desktop notification.
Each run:

1. fetches `main` into its own clone, `/var/lib/self-deploy/repo`;
2. stops when the host runs a clean release of `main` and boots the same system;
3. stops, with the run failed, when the deploy of this `main` failed before, and
   prints when it failed and its exit status;
4. stops when `main` evaluates to the system that already runs and the host
   boots it;
5. otherwise runs `./deploy.sh <host> switch` on the host itself, with the
   deploy lock, the rollback timer and the checks of
   [What the deploy does](#what-the-deploy-does).

A main whose deploy failed is not deployed again until `main` moves, as on
nixos-rog. After the activation, a try has already restarted services and undone
the change, and a failed build fails again. Exit 70 and 77 (another deploy is
under way) do not fail the run, but the same status in two runs in a row does,
because a deploy that long is stuck. Exit 71, 74 and 79 fail the run, and the
next run tries again, because none is the fault of `main`. Exit 78 fails the
run until the work of the running release reaches `main`, or until someone runs
`./deploy.sh --replace <host> switch` from a checkout of `main` on nixos-desktop
or nixos-rog.

**Who sees a failure.** A failed run leaves `self-deploy.service` in the failed
state, which `systemctl --failed` lists, and writes its reason at journal
priority err (`journalctl -u self-deploy -p err`). The script sets the priority
with a leading `<N>` on a line of its output, such as `<3>` for err and `<4>`
for warning. The run stays failed, and
repeats its line every 2 hours, until `main` moves or someone fixes the cause.
The host ships the lines of `self-deploy.service` and
`self-deploy-reboot.service` at priority info and above to SigNoz
(`oruc.telemetry.journalUnits`, which `nixosModules/deploy-host.nix` sets),
where the failure line is the signal. The SigNoz alert rules live in
statuslantern-scraper's `deploy/signoz/alerts/`, and none of them reads these
units yet. A rule there is checked against live data before it is pushed, so
the rule for these units comes after the host's first NixOS deploy ships its
lines. Until then only someone on the host sees a failure. A held-back reboot and an outage of GitHub
during the clone or fetch log at priority warning and do not fail the run. To
clear the failed state by hand, run
`sudo systemctl reset-failed self-deploy.service`.

**Limits.** The unit loads a GitHub token as a credential when the host sets
`oruc.deploy.self.githubTokenFile`, and `github_config` in
`scripts/lib/pull-main.sh` writes it to a private `nix.conf` and `gh` config
under the unit's runtime directory, as nixos-rog's unit does
([Deploy unit](nixos-rog.md#deploy-unit)). It points `NIX_CONFIG` and
`GH_CONFIG_DIR` at them. Shell builtins write the files, so the token is never
in a command line, and the exported variables carry paths only. devbox sets it to its sops
secret ([Rotate the box's token](devbox.md#rotate-the-boxs-token)).
Nix fetches the flake inputs through GitHub's API. Without a token it stays
within the limit for a client without one, 60 requests an hour, which is too low
for an evaluation, and `deploy.sh` cannot ask `gh` which pull request merged a
running release. A release that someone test-deployed from a branch, and that
later merged as a squash, then makes the run exit 78 until someone runs
`--replace`.

A failed download in the evaluation, such as GitHub's API limit or an outage
after the fetch succeeded, says nothing about `main`. The run fails and writes
its reason at priority err, records no failed `main`, and the next run tries
again. While the cause lasts, every run fails the same way, every 2 hours.
nixos-rog's run does the same for its build. Only an `error:` line that says
`unable to download` counts, because Nix also prints a warning for each retry of
a download that later succeeds. Any other error is the fault of `main`
(`exit_on_download_failure` in `scripts/lib/pull-main.sh`).

**Time and memory limits.** The unit stops a run after 3 hours
(`TimeoutStartSec` in `nixosModules/deploy-unit.nix`, shared with nixos-rog's
deploy unit). Without a limit, one hung network call keeps the unit active and
the timer never starts it again. The slowest deploy of 119 runs of nixos-rog's
old updater took 659 s (journal, 2026-10-16 to 2026-10-23), and the rest of the
3 hours is room for compiling packages that no cache holds. A stop sends the
script SIGTERM, and its trap reports. A stop during `deploy.sh` leaves the
rollback timer to restore the previous system. `MemoryHigh = "12G"` slows the
run above 12 GiB and never kills it, so the script's traps still report, which a
`MemoryMax` kill would skip. The old updater, which also evaluated every host,
peaked at 7.5 GiB (journal, 2026-10-26).

**Why root.** A deploy from nixos-desktop or nixos-rog logs in as root over
Tailscale SSH, because omer's sudo needs a password on a server and a deploy
cannot type it. Passwordless sudo comes only with the `remoteAccess` feature
(`nixosModules/connectivity.nix`), which the schema allows on workstations only.
The `deployLogin` field of the host's machine record (`machines/schema.nix`)
names that user, and `deploy.sh` and `scripts/affected-hosts.sh` log in as it,
since the `devbox` alias in `~/.ssh/config` logs in as omer for the
editors. The timer's deploys
run as root with `HOME=/root` as well. So the lock, the release records and
`scripts/affected-hosts.sh --running` use one set, under
`/root/.local/state/nixos-config-deploy/`, for a timer deploy and a remote one.
Run a deploy on the box itself as root too (`sudo -i`); one as omer keeps its
lock and records in omer's home, where the timer's deploys and
`scripts/affected-hosts.sh --running` do not look.
`upgrade` on the host starts the unit, because a deploy as omer would write its
records to omer's home.

**The reboot.** `self-deploy-reboot.timer` starts `self-deploy-reboot.service`
at 02:10 UTC every day (`*-*-* 02:10:00 UTC`). The service schedules a reboot
in one minute when the kernel, the initrd or the kernel modules of
`/run/booted-system` differ from those of `/run/current-system`, because a
deploy since the boot changed them. The test is the one that NixOS's own upgrade
reboot uses. It compares the kernel modules too, which hold the modules the
running kernel loads. It skips the night, with a warning at priority warning,
when the boot default is not the running system (a `test` deploy leaves the boot
default behind, and a reboot would drop what runs now), or when a deploy or
devbox's nightly update runs, a deploy holds the lock or has armed a rollback
timer. A skip exits 0, and the next night
tries again. It never starts a deploy. A deploy or a nightly update
that starts within that one minute can still be cut short by the reboot. After
a deploy cut short, the host boots the previous system, the boot default that
the deploy had not yet replaced. Limine counts no boot attempts, so a new kernel that does not
boot leaves the host down until someone opens the provider's console and picks
the previous entry from Limine's menu; nothing reports it. For devbox, an agent
can open the console of netcup's Server Control Panel with agent-browser; no
one has tried that path yet. The telemetry work
that ships the journal is where an alert on a missing host belongs.

**The session check.** SSH can still answer while a switch broke the desktop.
The deploy user's running services form the session check of step 10 below,
such as the compositor, the shell and the keyring. The running system lists the
services to leave out in `/etc/nixos-config-deploy/session-ignore`, one shell
glob per line. They are long-running agents that a switch may restart and that
no deploy should undo. A host sets
the list with `oruc.deploy.sessionIgnore`; a host without the option has no
file and leaves out nothing more. On devbox the list holds the
long-running agents of omer. A deploy of that host runs as root, whose session
has none of them, so the list matters only for a deploy as omer.

To pause the deploys on the host until the next reboot, mask
`self-deploy.timer` in `/run/systemd/system.control` and stop it, as the
[deploy unit](nixos-rog.md#deploy-unit) of nixos-rog shows, and wait until
`systemctl is-active self-deploy.service` prints `inactive` or `failed`.
Resume them by running
`sudo rm /run/systemd/system.control/self-deploy.timer`,
`sudo systemctl daemon-reload` and `sudo systemctl start self-deploy.timer`.

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
   specialisations together, plus 1 GiB. Each boot entry copies its kernel and
   initrd to the ESP before the installer removes old ones, so a nearly full ESP
   would fail halfway through. The deploy counts every distinct kernel and
   initrd of the candidate and its specialisations, even those already on the
   ESP. Every host has a 4 GiB ESP, and the 1 GiB left free covers a few more
   generations. Without that room, it exits 74 and does not touch the ESP, and
   nothing on the target has changed.
10. For `switch` and `test`, when the deploy user is logged in, it records that
    user's running services, because SSH can still answer while the switch broke
    the desktop. The session is the compositor, the shell and the keyring. The
    list leaves out these services, which come and go on their own:
    - services that a timer, socket or path started
    - apps that a launcher or autostart started (`app-*`)
    - `systemd-run` jobs (`run-*`)
    - transient D-Bus services (`dbus-*`)
    - services that the running system lists for this check, such as
      long-running agents that a switch may restart
      ([The session check](#self-deploy-of-a-server))

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

Activation starts a new system service but leaves running user services as
they were. A user service that looks for a system service only when it starts
misses one that the deploy added. Plasma's powerdevil finds
power-profiles-daemon this way, so after a deploy that first enables the
daemon, the battery applet shows "Power Profile: Not available" until
`systemctl --user restart plasma-powerdevil.service`. This command lists the
profiles the applet shows:

```sh
busctl --user call org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement/Actions/PowerProfile org.kde.Solid.PowerManagement.Actions.PowerProfile profileChoices
```

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

The table lists every code from 64 to 99 that `deploy.sh` and `scripts/pull-main.sh` set.
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
| 77 | Another deploy holds the lock on the host. | Unchanged. |
| 78 | A running or boot-default release holds files that this checkout lacks. | Unchanged. |
| 79 | `/boot` is not mounted. | Unchanged. |
| 80 | The candidate's units hold an ordering cycle, so the next boot would not finish. | Unchanged. |

nixos-rog's deploy unit (`scripts/pull-main.sh`) and a server's self-deploy
(`scripts/self-deploy.sh`) share `deploy_main` in `scripts/lib/pull-main.sh`.
It sorts the exit status of `deploy.sh` into four outcomes:

- **done.** The status is 0, and the host runs `main`.
- **wait.** The status is 70 (the rollback timer of another deploy is pending),
  77 (another deploy holds the lock) or 78 (a running release holds files that
  `main` lacks). None of them changed the host.
- **retry.** The status is 71 (the rollback timer could not be armed), 74 (the
  ESP is full) or 79 (`/boot` is not mounted). None is the fault of `main`, so
  the next run tries again.
- **failed.** Any other status, such as a build that fails again, or 73, after
  which the host runs `main` while the next boot starts the previous system.

`deploy_main` asks `systemctl is-active deploy-rollback.timer` before it starts
`deploy.sh`, and takes status 70 without running it when the timer is active.
`deploy.sh` uploads a release in step 3 before it finds a pending rollback timer
in step 4, so asking first keeps a held-back run from leaving a release behind.

## One deploy at a time

Only one deploy runs on a host at a time. A second deploy exits 77 and names
the deploy that holds the lock.

The target's shell takes the lock with `flock` on `deploy.lock` in
`~/.local/state/nixos-config-deploy/` and holds it while it reads the deploy's
open pipe. The lock goes when that deploy exits or loses its connection.
Keepalives on both ends close a dead connection. The deploy's `ssh` probes every
10 seconds and ends the connection after 3 missed probes, 30 seconds. The
target's sshd (`nixosModules/ssh.nix`) probes every 15 seconds and ends it after
3 missed probes, 45 seconds. The target's end frees the lock, so the lock is
free within about 45 seconds.

When a deploy finds its own lock dropped before activation, another deploy may
have run since. It does these steps:

1. It takes the lock again.
2. It repeats the release check in
   [Dirty trees and other checkouts](#dirty-trees-and-other-checkouts).
3. It reads the running system again, because the rollback must restore that
   one.

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
that merged, because the merge puts that version in `main`'s history. A clean
release of an earlier commit of the branch also passes once its PR merged:
GitHub must list the release's commit in a merged PR, and that PR's merge
commit must be in this checkout's history. Without GitHub, such a release
makes the deploy exit 78. The check compares the candidate files first and
reads Git history only for files that differ.

A system with no release record, such as one built by hand, is reported and not
checked. `--replace` skips the check.

The last line says how to continue. It compares this checkout with its local
`origin/main`, so run `git fetch` first when the clone may be old:

- When the checkout shares no history with `origin/main`, the repository's
  history was likely rewritten. A checkout with no work of its own continues
  after `git fetch origin && git reset --hard origin/main`.
- When the checkout is behind `origin/main`, it continues after `git pull`.
- Otherwise merge the work into this checkout. Or, after the owner of that
  work agrees, rerun with `--replace`, as in
  `./deploy.sh --replace nixos-rog test`.

`--replace` drops the other checkout's work from the host, so it is wrong for
a checkout that is only out of date.

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
2. Fix the source in this checkout. When you also try a fix with a rebuild on
   the target, apply the same fix here.
3. Run `scripts/check.sh` again.
4. Run the same deploy command again. For example, rerun the `test` action,
   which does not persist:

   ```sh
   ./deploy.sh nixos-latitude test
   ```

   The deploy prints `Deployment completed from release <release>.`
