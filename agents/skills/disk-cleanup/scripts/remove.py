#!/usr/bin/env python3
"""Remove rows from the latest disk-cleanup survey, one row at a time.

A row is one path, or a group whose paths each pass the checks on their own;
a single path from a group can be named too. Every check runs before a path
goes, in this order, and the first failure keeps that path; the other paths
go on:

1. The row is a delete row in the latest survey.json, or a look row whose
   paths go to the Trash (config.TRASH_SUFFIX).
2. No process uses the path (holders.py). For the Chrome on-device model and
   Chrome's cache, a running Chrome counts. The processes are read once for
   the checks, and again for all of a row's paths just before the row's first
   path goes, so a path that gains a user while earlier rows delete is kept. A
   user that appears after that read, such as while the row's earlier paths
   delete, is not seen.
3. The path is not protected (classify.protected), whatever its class says: a
   symlink; outside ~, /tmp, and /var/tmp; one of the survey's group
   directories, such as ~ or ~/.cache, itself; a leave path or a directory
   that holds one; or a directory with a mount point at or under it.
4. No symlink in ~/.local/bin resolves inside it, which covers the live
   sibling of a versions/ tree.
5. It has not changed within its row's window. The tree is read again here,
   since work may touch it after the survey. A /tmp folder bound for the
   Trash also holds no unfinished work (activity.unfinished), read again here.

A path that is already gone gets no check and shows as "already gone".

Docker rows name objects, not paths, and take these checks in place of 2 to 5,
read again from the tool here:

- An image (`docker-image`): 2, no container, running or stopped, uses it;
  6, the registry still has it: every `repo@digest` it carries answers 200.
  Docker Hub gets a HEAD request with an anonymous token from
  auth.docker.io, which does not count against the pull limit; any other
  registry gets `docker buildx imagetools inspect` with the stored login. A
  local build with a Docker Hub name fails 6 unless Docker Hub holds those
  exact bytes. `docker rmi` then removes every reference the image carries.
- An untagged image (`docker-untagged`): 2, no container, running or
  stopped, uses it; 3, it still has no tag; 5, it was made 24+ h ago and
  no running agent (a live Claude Code session or a Codex thread) named it within 24 h; 6,
  the registry still has every `repo@digest` it carries, as for a pulled
  image. `docker rmi` removes each of them.
- A volume (`docker-volume`): 2, no container uses it; 3, it still has the
  anonymous label; 5, it was created 24+ h ago.
- A stopped container (`docker-container`): 2, it is still exited; 5, it
  exited 24+ h ago.
- The build cache (`docker-builder`) runs last, after the image rows, since
  records shared with a removed image only become reclaimable then. Its
  prune keeps records used within 24 h.

Before the Chrome on-device model goes, the switch in Chrome's Local State is
written false, so Chrome stops downloading it. A Local State that is missing,
not UTF-8, or not valid JSON keeps the model. A path that `rm` cannot remove
gets `chmod -R u+rwX` and one more `rm`, since Go and Gradle leave read-only
directories.

Then sync and read `df` on each filesystem the row's paths are on (the
Docker root's for a Docker row), remove the row's paths as its `how` says
(COMMANDS or MOVERS), sync and read `df` there again. A stale /tmp folder
(`tmp-trash`) goes to the Trash by a rename; when /tmp is another mount, by a
reflink copy, or by a full copy when the Trash has room for it. `trash-purge`
deletes it from there once the survey offers it in group:tmp-trash. A drop that misses Frees (learn.missed) gets one
more sync and reading, and the table shows both. A path moved to the Trash
frees nothing yet, so it gets no reading. `--dry-run` runs the same code with
removal off and prints the same table: Path, Frees, Drop, Result. Exits 1
when any path stays. A real run writes a record for learn.py.
"""

import argparse
import contextlib
import dataclasses
import datetime
import errno
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from functools import cache

from activity import session_mentions, unfinished
from classify import bin_links, leave_paths, protected, recent, scanned_docker_root
from config import OUT_DIR, RECENT, TRASH_DIR
from docker import ANONYMOUS, created, dangling_volumes
from filesystems import filesystem, fs_mounts, used
from holders import HOME, Hit, inside, tilde, users
from learn import atomic_write, missed, record, trashed, write_trashed
from measure import walk_tree
from report import bounded
from rows import Row, run, size

CHROME_STATE = f"{HOME}/.config/google-chrome/Local State"
COMMANDS = {
    "rmdir": ["rmdir", "--"],
    "trash": ["gio", "trash", "--"],
    "docker-image": ["docker", "rmi", "--"],
    "docker-untagged": ["docker", "rmi", "--"],
    "docker-volume": ["docker", "volume", "rm", "--"],
    "docker-container": ["docker", "rm", "--"],
    "docker-builder": ["docker", "builder", "prune", "-f", "--filter", f"until={RECENT // 3600}h"],
}


def _run(cmd: list[str]) -> None:
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode:
        raise OSError((proc.stderr.strip().splitlines() or [f"`{cmd[0]}` failed"])[-1])


def rm_tree(path: str) -> None:
    """`rm -rf`, then once more after `chmod -R u+rwX`.

    rm cannot unlink an entry of a read-only directory, and Go's module cache
    and Gradle's toolchains make their directories read-only.
    """
    try:
        _run(["rm", "-rf", "--one-file-system", "--", path])
    except OSError:
        subprocess.run(["chmod", "-R", "u+rwX", "--", path], capture_output=True, check=False)
        _run(["rm", "-rf", "--one-file-system", "--", path])


def copy_to_trash(path: str, target: str) -> None:
    """Copy path to target by reflink, or in full when the filesystems differ."""
    subprocess.run(["chmod", "-R", "u+rX", "--", path], capture_output=True, check=False)
    try:
        _run(["cp", "-a", "--reflink=always", "--", path, target])
        return
    except OSError:
        pass
    # cp may leave a partial target, and a second cp into it would nest path inside.
    rm_tree(target)
    need, st = walk_tree(path).alloc, os.statvfs(os.path.dirname(target))
    if need > (free := st.f_bavail * st.f_frsize):
        raise OSError(f"a full copy needs {size(need)}; the Trash has {size(free)} free")
    _run(["cp", "-a", "--reflink=never", "--", path, target])


def tmp_trash(path: str) -> None:
    """Move a /tmp or /var/tmp folder to the Trash.

    A rename fails with EXDEV when /tmp is another mount than the Trash, as
    rename(2) says, such as a btrfs subvolume or a tmpfs of its own; then a
    reflink copy shares the extents, so the move needs no free space. A
    reflink cannot cross filesystems, so then a full copy needs the folder's
    allocated size free in the Trash's filesystem. The source stays until the
    copy succeeds. The .trashinfo file comes first and reserves the name, as
    the freedesktop Trash spec asks:
    https://specifications.freedesktop.org/trash-spec/latest/
    """
    os.makedirs(f"{TRASH_DIR}/files", exist_ok=True)
    os.makedirs(f"{TRASH_DIR}/info", exist_ok=True)
    base, n = os.path.basename(path), 1
    while True:
        name = base if n == 1 else f"{base}.{n}"
        info = f"{TRASH_DIR}/info/{name}.trashinfo"
        try:
            fd = os.open(info, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            n += 1
            continue
        if not os.path.lexists(f"{TRASH_DIR}/files/{name}"):
            break
        os.close(fd)
        n += 1
    with os.fdopen(fd, "w") as f:
        f.write(f"[Trash Info]\nPath={urllib.parse.quote(path)}\nDeletionDate={time.strftime('%Y-%m-%dT%H:%M:%S')}\n")
    target = f"{TRASH_DIR}/files/{name}"
    try:
        write_trashed(trashed() | {name: path})
        copied = move_to_trash(path, target)
    except OSError:
        with contextlib.suppress(OSError):
            rm_tree(target)
        with contextlib.suppress(OSError):
            write_trashed({k: v for k, v in trashed().items() if k != name})
        os.remove(info)
        raise
    if copied:
        rm_tree(path)


def move_to_trash(path: str, target: str) -> bool:
    """Rename path to target, or copy it there when they are on different mounts; True when it copied."""
    try:
        os.rename(path, target)
        return False
    except OSError as e:
        if e.errno != errno.EXDEV:
            raise
    copy_to_trash(path, target)
    return True


def trash_purge(path: str) -> None:
    """Delete a Trash entry tmp_trash made, with its .trashinfo file."""
    name = os.path.basename(path)
    rm_tree(path)
    if os.path.lexists(info := f"{TRASH_DIR}/info/{name}.trashinfo"):
        os.remove(info)
    write_trashed({k: v for k, v in trashed().items() if k != name})


MOVERS = {"rm": rm_tree, "tmp-trash": tmp_trash, "trash-purge": trash_purge}
NO_READING = ("trash", "tmp-trash")

OBJECTS = {"docker-image": ("docker", "image"), "docker-untagged": ("docker", "image"),
           "docker-volume": ("docker", "volume"), "docker-container": ("docker", "container"),
           "docker-builder": None}
MANIFESTS = ("application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, "
             "application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json")


def write_chrome_switch(_: str) -> None:
    """Set the on-device model switch to false with an atomic rename."""
    with open(CHROME_STATE, encoding="utf-8") as f:
        try:
            state = json.load(f)
        except ValueError as e:  # bad JSON, or bytes that are not UTF-8
            raise OSError(f"Local State is not valid UTF-8 JSON: {e}") from e
    if not isinstance(state, dict):
        raise OSError("Local State is not a JSON object")
    state.setdefault("optimization_guide", {})["on_device_foundational_model_user_settings"] = False
    atomic_write(CHROME_STATE, json.dumps(state, separators=(",", ":")))


PREPARE = {
    f"{HOME}/.config/google-chrome/OptGuideOnDeviceModel": write_chrome_switch,
}


def row_check(row: Row | None) -> str | None:
    """Check 1, or None when it passes."""
    if row is None:
        return "1: not in the survey"
    if row.kind != "delete" and row.how != "trash":
        return f"1: a {row.kind} row: {row.reason}"
    return None


def use_check(held: list[Hit]) -> str | None:
    """Check 2 without its number, or None when no process uses the path."""
    return f"in use by `{held[0].name}` (pid {held[0].pid}, {held[0].how})" if held else None


def path_check(path: str, row: Row, held: list[Hit], leaves: set[str], links: list[str]) -> str | None:
    """The first check path fails, or None: 2 to 5, or an object's own checks."""
    if row.how in OBJECTS:
        return check(path) if (check := OBJECT_CHECKS.get(row.how)) else None
    if why := use_check(held):
        return f"2: {why}"
    if why := protected(path, leaves):
        return f"3: protected: {why}"
    if live := [t for t in links if inside(t, path)]:
        return f"4: `~/.local/bin` points into it ({tilde(live[0])})"
    if row.window and (reason := recent(walk_tree(path).changed, row.window)):
        return f"5: {reason}"
    if row.how == "tmp-trash" and (why := unfinished(path)):
        return f"5: {why}"
    return None


def inspect(tool: str, kind: str, name: str) -> dict | None:
    """`<tool> <kind> inspect` for name, or None; `inspected` caches it, and exists() asks again after removal."""
    proc = subprocess.run([tool, kind, "inspect", "--", name], capture_output=True, text=True, check=False)
    return json.loads(proc.stdout)[0] if proc.returncode == 0 else None


inspected = cache(inspect)
dangling = cache(dangling_volumes)


@cache
def container_images() -> dict[str, str]:
    """Image ID, then the name of one container that uses it, running or stopped."""
    ids = run(["docker", "ps", "-aq", "--no-trunc"]).split()
    if not ids:
        return {}
    return dict(line.split(" ", 1) for line in run(["docker", "inspect", "--format", "{{.Image}} {{.Name}}", *ids])
                .splitlines())


def image_check(ref: str) -> str | None:
    image = inspected("docker", "image", ref)
    if name := container_images().get(image["Id"]):
        return f"2: container `{name.lstrip('/')}` uses it"
    if not image.get("RepoDigests"):
        return "6: no registry digest"
    for ref_digest in image["RepoDigests"]:
        if why := registry_check(ref_digest):
            return f"6: `{ref_digest[:60]}` {why}"
    return None


@cache
def hub_token(repo: str) -> str:
    with urllib.request.urlopen("https://auth.docker.io/token?service=registry.docker.io"
                                f"&scope=repository:{repo}:pull", timeout=15) as r:
        return json.load(r)["token"]


def registry_check(ref_digest: str) -> str | None:
    """None when the registry holds repo@digest, else what it answered."""
    name, _, digest = ref_digest.partition("@")
    host, _, rest = name.partition("/")
    if rest and ("." in host or ":" in host or host == "localhost") and host != "docker.io":
        proc = subprocess.run(["docker", "buildx", "imagetools", "inspect", "--raw", ref_digest],
                              capture_output=True, text=True, timeout=60, check=False)
        return None if proc.returncode == 0 else (proc.stderr.strip().splitlines() or ["failed"])[-1][-120:]
    repo = name.removeprefix("docker.io/")
    repo = repo if "/" in repo else f"library/{repo}"
    try:
        head = urllib.request.Request(f"https://registry-1.docker.io/v2/{repo}/manifests/{digest}", method="HEAD",
                                      headers={"Authorization": f"Bearer {hub_token(repo)}", "Accept": MANIFESTS})
        with urllib.request.urlopen(head, timeout=15):
            return None
    except urllib.error.HTTPError as e:
        return f"answers {e.code}"
    except (OSError, ValueError, KeyError) as e:
        return f"unreachable: {e}"


def untagged_check(ref: str) -> str | None:
    image = inspected("docker", "image", ref)
    if name := container_images().get(image["Id"]):
        return f"2: container `{name.lstrip('/')}` uses it"
    if tags := [t for t in image.get("RepoTags") or [] if "@" not in t]:
        return f"3: protected: tagged `{tags[0]}`"
    if not image.get("Created"):
        return "5: no creation time"
    if reason := recent(datetime.datetime.fromisoformat(image["Created"]).timestamp(), RECENT, "made"):
        return f"5: {reason}"
    if named := session_mentions([ref]).get(ref):
        return f"5: {named}"
    for ref_digest in image.get("RepoDigests") or []:
        if why := registry_check(ref_digest):
            return f"6: `{ref_digest[:60]}` {why}"
    return None if image.get("RepoDigests") else "6: no registry digest"


def container_check(name: str) -> str | None:
    state = inspected("docker", "container", name)["State"]
    if state["Status"] != "exited":
        return f"2: it is {state['Status']}"
    if reason := recent(datetime.datetime.fromisoformat(state["FinishedAt"]).timestamp(), RECENT, "exited"):
        return f"5: {reason}"
    return None


def volume_check(name: str) -> str | None:
    volume = inspected("docker", "volume", name)
    if name not in dangling():
        return "2: a container uses it"
    if ANONYMOUS not in (volume.get("Labels") or {}):
        return "3: protected: a named volume"
    if reason := recent(created(volume), RECENT, "created"):
        return f"5: {reason}"
    return None


OBJECT_CHECKS = {"docker-image": image_check, "docker-untagged": untagged_check, "docker-volume": volume_check,
                 "docker-container": container_check}


def exists(row: Row, name: str, look=inspect) -> bool | None:
    """Whether name is there; None for the build cache, which nothing looks up."""
    if row.how not in OBJECTS:
        return os.path.lexists(name)
    obj = OBJECTS[row.how]
    return None if obj is None else look(*obj, name) is not None


def operands(row: Row, name: str) -> list[str]:
    """What the row's command takes for name: an image goes by every reference it carries."""
    if row.how == "docker-builder":
        return []
    if row.how in ("docker-image", "docker-untagged"):
        return inspected("docker", "image", name).get("RepoTags") or [name]
    return [name]


@dataclasses.dataclass
class Outcome:
    result: str
    frees: int | None = None
    drops: list[int] = dataclasses.field(default_factory=list)
    kept: bool = False


def fill_shared_caches(row: Row) -> None:
    """Fill the lookups the worker threads share before they start."""
    if row.how in ("docker-image", "docker-untagged"):
        container_images()
    elif row.how == "docker-volume":
        dangling()


def users_now(row: Row, going: list[str]) -> dict[str, list[Hit]]:
    """The processes that use the paths now: the first read is minutes old, and a path no window guards can gain a user.

    One scan serves the whole row, so its cost does not grow with the paths.
    """
    return {} if row.how in OBJECTS else users(going)


def process(row: Row | None, held: dict[str, list[Hit]], leaves: set[str], links: list[str],
            docker_root: str | None, really: bool) -> Outcome:
    """Check a row's paths, and remove the ones that pass when really is set."""
    if failed := row_check(row):
        return Outcome(f"check {failed}", kept=True)
    paths = row.targets()
    present = [p for p in paths if exists(row, p, inspected) is not False]
    fill_shared_caches(row)
    with ThreadPoolExecutor(max_workers=8) as pool:
        checks = dict(zip(present, pool.map(lambda p: path_check(p, row, held.get(p, []), leaves, links), present),
                          strict=True))
    kept = [(p, f"check {c}") for p, c in checks.items() if c]
    going = [p for p, c in checks.items() if not c]
    out = Outcome("", frees=sum(paths[p] for p in going))
    if really and going:
        mounts = fs_mounts([docker_root] if row.how in OBJECTS else going)
        before = used(mounts) if row.how not in NO_READING else 0
        fresh = users_now(row, going)
        for p in going:
            try:
                if why := use_check(fresh.get(p, [])):
                    raise OSError(f"{why}, seen again just before removal")
                if p in PREPARE:
                    PREPARE[p](p)
                if mover := MOVERS.get(row.how):
                    mover(p)
                else:
                    _run([*COMMANDS[row.how], *operands(row, p)])
                if exists(row, p):
                    raise OSError("files are left")
            except OSError as e:
                kept.append((p, f"failed: {e}"))
        if row.how not in NO_READING:
            out.drops = [before - used(mounts)]
            if missed(out.frees, out.drops[0]):
                out.drops.append(before - used(mounts))
    out.kept = bool(kept)
    out.result = result(row, len(paths), len(paths) - len(present), len(going), kept, out, really)
    return out


def result(row: Row, total: int, gone: int, going: int, kept: list[tuple[str, str]], out: Outcome,
           really: bool) -> str:
    """The Result cell: what happened, the first path kept and why, and a missed estimate."""
    if total == 1 and (kept or gone):
        return kept[0][1] if kept else "already gone"
    done = going - sum(why.startswith("failed") for _, why in kept)
    count = "" if total == 1 else f" {done} of {total}"
    if row.how in NO_READING:
        text = f"{'moved' if really else 'would move'}{count} to the Trash"
    else:
        text = f"{'removed' if really else 'would remove'}{count}"
    if gone:
        text += f"; {gone} already gone"
    if kept:
        more = f", and {len(kept) - 1} more" if len(kept) > 1 else ""
        text += f"; kept `{tilde(kept[0][0])}`: {kept[0][1]}{more}"
    if out.drops and out.frees and missed(out.frees, out.drops[-1]):
        text += f"; drop is {(out.drops[-1] - out.frees) / out.frees:+.0%} off Frees"
    return text


def pick(name: str, rows: dict[str, Row], member_of: dict[str, Row]) -> Row | None:
    """The row name stands for; one entry of a group stands for itself alone."""
    if name in rows:
        return rows[name]
    if group := member_of.get(name):
        return dataclasses.replace(group, path=name, members=None, frees=group.members[name], inodes=0)
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="Remove rows from the latest disk-cleanup survey.")
    parser.add_argument("--dry-run", action="store_true", help="run every check and change nothing")
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--all", action="store_true", help="every delete row in the survey")
    target.add_argument("paths", nargs="*", default=[], metavar="PATH",
                        help="a row's path, a group such as group:stale-cache, or one path of a group")
    args = parser.parse_args()
    try:
        with open(os.path.join(OUT_DIR, "survey.json")) as f:
            survey = json.load(f)
    except OSError:
        print("No survey.json; run survey.py first.", file=sys.stderr)
        return 2
    if "docker_root" not in survey:
        print("survey.json comes from an older survey.py; run survey.py again.", file=sys.stderr)
        return 2
    docker_root = survey["docker_root"]
    if docker_host := survey["docker_host"]:
        os.environ["DOCKER_HOST"] = docker_host
        os.environ.pop("DOCKER_CONTEXT", None)
    rows = {r["path"]: Row(**r) for r in survey["rows"]}
    member_of = {p: r for r in rows.values() if r.members is not None for p in r.members}
    if args.all:
        names = [p for p, r in rows.items() if r.kind == "delete"]
    else:
        names = [p if p in rows or p in member_of else os.path.abspath(os.path.expanduser(p)) for p in args.paths]
    picked = {n: pick(n, rows, member_of) for n in names}
    picked = dict(sorted(picked.items(), key=lambda kv: kv[1] is not None and kv[1].how == "docker-builder"))
    leaves, links = leave_paths(rows.values(), scanned_docker_root(docker_root)), bin_links()
    held = users([p for r in picked.values() if r and r.how not in OBJECTS for p in r.targets() if os.path.lexists(p)])

    lines = ["| Path | Frees | Drop | Result |", "| --- | --- | --- | --- |"]
    log, kept = [], False
    for name, row in picked.items():
        inodes = row.inodes if row and row.members is None else 0
        fs = filesystem(name) if inodes else None
        out = process(row, held, leaves, links, docker_root, really=not args.dry_run)
        kept |= out.kept
        label = row.label() if row else f"`{tilde(name)}`"
        frees = "-" if out.frees is None or row.how in NO_READING else bounded(out.frees, row.bound)
        lines.append(f"| {label} | {frees} | {' then '.join(size(d) for d in out.drops) or '-'} | {out.result} |")
        log.append({"path": name, "refused": out.frees is None,
                    "unlisted": row is None or row.reason.startswith("unlisted"),
                    "measured": bool(inodes and out.drops and not out.kept),
                    "frees": out.frees, "drop": out.drops[-1] if out.drops else None,
                    "meta": fs.metadata_copies * fs.inode_metadata * inodes if fs else 0,
                    "inode_metadata": fs.inode_metadata if fs else 0, "fs_type": row.fs_type if row else ""})
    print("\n".join(lines))
    if not args.dry_run:
        skipped = [] if args.all else [p for p, r in rows.items()
                                       if r.kind == "delete" and p.startswith("/") and p not in picked]
        record("delete", {"time": time.time(), "survey": survey["generated"], "named": not args.all,
                          "skipped": skipped, "rows": log})
    return 1 if kept else 0


if __name__ == "__main__":
    sys.exit(main())
