# Measurements and choices behind the survey

Each section names the constant in `scripts/config.py` (or the module that owns it) and the evidence or decision that set it. Change a value only with a new measurement.

## Windows and ages

- `RECENT` (24 h) is a choice. A delete row that needs a command to come back moves to look when anything in it changed this recently, because an agent session can use it between two commands, where `holders.py` sees no process. The case that set it: an agent session changed a `node_modules` folder 80 minutes before a survey and was still running; that session ran for more than 3 hours. The same window applies to `/tmp`, `/var/tmp`, and incomplete downloads.
- `STALE` (30 days) is a choice. A `~/.cache` entry unchanged this long goes on delete, and a big user file this old shows on look. nixos-desktop and nixos-rog mount `/home` with `noatime`, and devbox mounts `/` with `relatime`, so atime does not show every read. "Unchanged" is the newest ctime, so a cache that is read every day but never written counts as stale.
- `TRASH_AGE` (7 days) is Omer's choice of 06-10-2026. A stale `/tmp` or `/var/tmp` folder can hold an agent's only copy of its work, so `remove.py` moves it to the Trash, and a survey `TRASH_AGE` later offers it in `group:tmp-trash`.
- `AREAS` ages for `/tmp` (10 days) and `/var/tmp` (30 days) are the `q` lines of `tmp.conf` in `systemd-tmpfiles --cat-config`. `/tmp` is on disk and nothing clears it at boot, so its folders count against `df` until tmpfiles removes them.

## Paths and searches

- `CLAUDE_TMP` is Claude Code's per-uid temp directory. Each project's task output sits in a folder named for the project path, such as `-home-oruc`; every other entry is a folder an agent made. On 06-10-2026 those folders held 44 GiB.
- `AGENTS_TMP` holds each agent task's scratch folder, named with its session ID, so each folder is its own entry and its name can tie it to a running agent.
- `GROUP_DIRS`: a look row is a child of the deepest group directory above it.
- `BUILD_TREES`: `node_modules/` and `target/` are build output only under `~/Desktop`, `/tmp`, and `/var/tmp`. Elsewhere they belong to an installed tool, and nothing reinstalls them on its own.
- `GROUP_BY_NAME` puts a file in a group by name, anywhere in `~` outside leave paths and git work trees. A `__pycache__` directory joins `group:pycache`.
- `NAME_SEARCH_DEPTH` (12) is how deep the name search goes; it is Kudu's `recursiveMatch` default.
- `UNFINISHED_DEPTH` (3) is how deep `unfinished()` looks inside a `/tmp` folder. 3 reaches a clone three folders down, which held 1338 unpushed commits on 06-10-2026.
- `BACKUP_HOME`: a copy of another host's home is a `home` folder anywhere under `~/backups`, such as `~/backups/<host>/home`.
- `HANDOFFS` is `~/handoffs`. An agent hands work to another session in a file there and names the `/tmp` folders that hold it.

## Class tables

`tables.json`, merged with this host's overlay, holds these tables:

- `delete`: path, then when the bytes come back. The tool refills these on its next run.
- `delete_by_command`: path, then the command that brings the bytes back. Nothing refills these on its own, so the `RECENT` rule applies to them.
- `leave`: path, then why it stays. Delete rules never apply inside these.
- `backup_delete`: path inside a backed-up home, then what it holds and how it comes back on the host that home came from. Nothing on this host uses it.
- `backup_trash`: the same for paths that also hold data that does not come back; they go on look, to the Trash when named.
- `inode_metadata`: filesystem type, then its metadata bytes per inode, fitted to measured deletes; a type it does not list counts 0.

## Size estimates

- nixos-desktop and nixos-rog mount one btrfs filesystem with `zstd:1`. A 15,882-inode `node_modules` copy added 15.4 MiB of metadata and 178.5 MiB of data against an estimate of 178.0 MiB, measured before the move to NixOS on 22-10-2026.
- Docker's root directory belongs to root, or to subordinate uids for rootless Docker, and on nixos-desktop btrfs zstd stores it smaller than Docker counts. Two `docker builder prune` runs on 28-09-2026, before the move to NixOS, reported 44.95 GB and 8.517 GB, and `df` dropped 24.1 GiB and 5.3 GiB, 0.58 and 0.67 of it. A Docker row's Frees is Docker's own size, an upper bound.

## Learning rules (`learn.py`)

- `KEEP` (20 records of each kind) is a choice: 4 times the longest look-back of 5 surveys.
- `MISS` (5%) and `NOISE` (2 MiB): the estimate missed by at most 1% in seven checks before the move to NixOS (three write probes, two deletes in Omer's run at 134 vs 135 MiB and 129 vs 129 MiB, and two scratch deletes at 135 vs 135 MiB and 32 vs 32 MiB). The one larger miss, 118 vs 134 MiB, was the only path whose first `df` reading had no sync before it. 5% leaves room for other writers, which moved `df` by at most 1.1 MiB a second; a removal's two readings are about a second apart, so a miss under `NOISE` is those writers.
- `ABSENT_SPAN` (30 days) is a choice. The absent rule needs its 5 surveys to span this long, so a tool used once a month keeps its entry through a burst of runs. 17 of the 48 entries were missing on 28-09-2026.
