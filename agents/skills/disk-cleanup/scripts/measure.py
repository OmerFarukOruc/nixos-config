"""Walks and size estimates: what is on disk and what a delete frees."""

import fcntl
import os
import re
import stat
import struct
import subprocess
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from typing import NamedTuple

from config import (
    AREAS,
    CLAUDE_TMP,
    DELETE,
    DELETE_BY_COMMAND,
    FLOOR,
    GIT_DIR,
    GROUP_BY_NAME,
    JUNK,
    LEAVE,
    NAME_SEARCH_DEPTH,
    OUT_DIR,
    RUNTIME_PREFIXES,
    SCAN,
    STALE,
    TRASH_SUFFIX,
    USER_DIRS,
)
from filesystems import Fs, filesystem
from holders import HOME, inside, users
from rows import CommandError, day

try:
    from compression import zstd
except ImportError:  # Python before 3.14: the drop becomes the upper bound
    zstd = None

FS_IOC_FIEMAP = 0xC020660B
FIEMAP_HEAD = struct.Struct("=QQLLLL")
FIEMAP_EXTENT = struct.Struct("=QQQQQLLLL")
LAST, ENCODED, INLINE, SHARED = 0x1, 0x8, 0x200, 0x2000
NO_EXTENT = 0x2 | 0x4  # unknown, delalloc
FIEMAP_FLAG_SYNC = 0x1  # write a file's dirty pages first, so data not yet on disk maps as extents
CHUNK, SECTOR = 128 * 1024, 4096
THREADS, FILES_PER_TASK = 8, 256


def scan() -> tuple[dict[str, int], list[str]]:
    """Every file and directory at or above the floor, in allocated bytes."""
    # du exits 1 after an unreadable directory and still prints every other size.
    proc = subprocess.run(["du", "-x", "-a", "-B1", f"--threshold={FLOOR}", *SCAN],
                          capture_output=True, text=True, check=False)
    sizes = {}
    for line in proc.stdout.splitlines():
        b, _, path = line.partition("\t")
        sizes[path] = int(b)
    unreadable = re.findall(r"cannot (?:read directory|access) '([^']+)'", proc.stderr)
    return sizes, unreadable


class Bytes(NamedTuple):
    shared: int
    excl: int
    data: int
    inline: int


class Reclaim(NamedTuple):
    excl: int
    shared: int
    frees: int
    inodes: int
    changed: float  # newest ctime: npm and pnpm write 1985 mtimes
    fs: Fs


def reclaim(paths: list[str]) -> list[Reclaim]:
    """Exclusive, shared, and expected-drop bytes for everything under each path.

    A file with a hard link outside its path survives the delete, so its
    bytes count as shared. The walks run in parallel, then the files of every
    path do, in batches, so one large path does not hold the run to one thread.
    """
    fss = [filesystem(p) for p in paths]
    with ThreadPoolExecutor(max_workers=THREADS) as pool:
        walks = list(pool.map(_inodes, paths))
        batches = [(n, w.files[i:i + FILES_PER_TASK])
                   for n, w in enumerate(walks) for i in range(0, len(w.files), FILES_PER_TASK)]
        non_regular = [w.non_regular_bytes if fs.non_regular_blocks_are_data else 0
                       for w, fs in zip(walks, fss, strict=True)]
        sums = [Bytes(w.linked, b, b, 0) for w, b in zip(walks, non_regular, strict=True)]
        for (n, _), got in zip(batches, pool.map(lambda b: _file_bytes(b[1], fss[b[0]].zstd_level), batches),
                               strict=True):
            sums[n] = Bytes(*(a + b for a, b in zip(sums[n], got, strict=True)))
    return [Reclaim(excl, shared, data + fs.metadata_copies * (inline + fs.inode_metadata * w.inodes), w.inodes,
                    w.changed, fs)
            for w, fs, (shared, excl, data, inline) in zip(walks, fss, sums, strict=True)]


class Walk(NamedTuple):
    """What deleting a path frees.

    files are the regular files, non_regular_bytes the st_blocks of the directories and symlinks, linked
    the bytes of files with a hard link outside the path, inodes the inodes, and changed the newest ctime.
    """

    files: list[tuple[str, os.stat_result]]
    non_regular_bytes: int
    linked: int
    inodes: int
    changed: float


def _inodes(path: str) -> Walk:
    changed = 0.0
    first: dict[tuple[int, int], tuple[str, os.stat_result]] = {}
    links_seen: Counter[tuple[int, int]] = Counter()
    for file, st, _ in lstat_tree(path):
        changed = max(changed, st.st_ctime)
        first.setdefault((st.st_dev, st.st_ino), (file, st))
        links_seen[(st.st_dev, st.st_ino)] += 1
    files, non_regular, linked, inodes = [], 0, 0, 0
    for key, (file, st) in first.items():
        if links_seen[key] < st.st_nlink and not stat.S_ISDIR(st.st_mode):
            linked += st.st_blocks * 512
            continue
        inodes += 1
        if stat.S_ISREG(st.st_mode):
            files.append((file, st))
        else:
            non_regular += st.st_blocks * 512
    return Walk(files, non_regular, linked, inodes, changed)


def _file_bytes(files: list[tuple[str, os.stat_result]], level: int | None) -> Bytes:
    """Shared, exclusive, expected-drop data, and inline bytes of files on a filesystem with zstd level."""
    shared = excl = data = inline = 0
    for file, st in files:
        try:
            fd = os.open(file, os.O_RDONLY | os.O_NOFOLLOW)
        except OSError:
            continue
        try:
            for logical, length, flags in _extents(fd):
                if flags & NO_EXTENT:
                    continue
                if flags & INLINE:
                    inline += _stored(os.pread(fd, st.st_size, 0), level)
                elif flags & SHARED:
                    shared += length
                else:
                    excl += length
                    data += _on_disk(fd, logical, length, level) if flags & ENCODED else length
        except OSError:
            pass
        finally:
            os.close(fd)
    return Bytes(shared, excl, data, inline)


def lstat_tree(path: str):
    """Yield (path, lstat, child names or None) for path and everything under it.

    The walk stays on path's filesystem, as `rm --one-file-system` does, and
    follows no symlink.
    """
    try:
        dev = os.lstat(path).st_dev
    except OSError:
        return
    stack = [path]
    while stack:
        top = stack.pop()
        try:
            st = os.lstat(top)
        except OSError:
            continue
        names = None
        if stat.S_ISDIR(st.st_mode) and st.st_dev == dev:
            try:
                names = os.listdir(top)
            except OSError:
                pass
            else:
                stack += [os.path.join(top, n) for n in names]
        yield top, st, names


def _extents(fd: int):
    start, count = 0, 256
    while True:
        buf = bytearray(FIEMAP_HEAD.pack(start, 2**64 - 1 - start, FIEMAP_FLAG_SYNC, 0, count, 0)
                        + bytes(FIEMAP_EXTENT.size * count))
        fcntl.ioctl(fd, FS_IOC_FIEMAP, buf, True)
        mapped = FIEMAP_HEAD.unpack_from(buf)[3]
        for i in range(mapped):
            logical, _, length, _, _, flags, *_ = FIEMAP_EXTENT.unpack_from(
                buf, FIEMAP_HEAD.size + i * FIEMAP_EXTENT.size)
            yield logical, length, flags
        if mapped < count or flags & LAST:
            return
        start = logical + length


def _stored(data: bytes, level: int | None) -> int:
    """Bytes btrfs keeps for data it may compress at zstd level: the smaller form."""
    if zstd is None or level is None:
        return len(data)
    return min(len(data), len(zstd.compress(data, level=level)))


def _on_disk(fd: int, logical: int, length: int, level: int | None) -> int:
    """Btrfs stores each compressed 128 KiB chunk rounded up to a sector."""
    total = 0
    for off in range(logical, logical + length, CHUNK):
        packed = _stored(os.pread(fd, min(CHUNK, logical + length - off), off), level)
        total += -(-packed // SECTOR) * SECTOR
    return total


class Tree(NamedTuple):
    """What lstat shows under a path.

    changed is the newest ctime, and socket means a socket is under it, so a running program may use it.
    empties holds each empty directory with its ctime and its owner.
    """

    changed: float
    socket: bool
    alloc: int
    empties: list[tuple[str, float, int]]


def walk_tree(path: str) -> Tree:
    """What lstat shows under path; reads nothing inside files.

    An empty directory inside a git directory, bare or not, is not in
    empties: git needs `refs` and `objects` to exist, and removing their empty
    children one run empties them for the next.
    """
    changed, socket, alloc, empties, git_dirs = 0.0, False, 0, [], []
    for top, st, names in lstat_tree(path):
        changed, alloc = max(changed, st.st_ctime), alloc + st.st_blocks * 512
        socket = socket or stat.S_ISSOCK(st.st_mode)
        if names == []:
            empties.append((top, st.st_ctime, st.st_uid))
        elif names and "refs" in names and GIT_DIR <= set(names):
            git_dirs.append(top)
    empties = [e for e in empties if not any(inside(e[0], g) for g in git_dirs)]
    return Tree(changed, socket, alloc, empties)


def area_walk() -> tuple[list[tuple[str, float, int]], dict[str, str]]:
    """Stale entries in each AREAS directory, and old empty directories there.

    An entry counts when it is yours, in no table, holds no socket, and has
    not changed within its area's window; it comes back as (path, changed,
    allocated). Inside an entry that does not count, each empty directory of
    yours that has not changed within the window counts; it comes back
    mapped to its entry, since a process that uses the entry uses it too.
    The walk skips an entry a process uses, since main() would drop both;
    /tmp/claude-1000 alone took 20 s to walk. It skips Claude Code's own
    project folders in CLAUDE_TMP too.
    """
    uid, now = os.getuid(), time.time()
    listed = {os.path.expanduser(k) for k in (*DELETE, *DELETE_BY_COMMAND, *LEAVE)}
    stale, empty, entries = [], {}, []
    for area, (window, _) in AREAS.items():
        try:
            entries += [(e, window) for e in os.scandir(area) if not claude_own(e.path) and e.path not in AREAS]
        except OSError:
            continue
    held = users([e.path for e, _ in entries])
    for e, window in entries:
        try:
            st = e.stat(follow_symlinks=False)
        except OSError:
            continue
        if (stat.S_ISLNK(st.st_mode) or st.st_uid != uid or e.path in listed or e.path == OUT_DIR
                or e.name.startswith(RUNTIME_PREFIXES) or held[e.path]):
            continue
        tree = walk_tree(e.path)
        if tree.socket:
            continue
        if now - tree.changed >= window and [d for d, *_ in tree.empties] != [e.path]:
            stale.append((e.path, tree.changed, tree.alloc))
        else:
            empty |= {d: e.path for d, changed, owner in tree.empties if owner == uid and now - changed >= window}
    return stale, empty


def name_walk(prune: set[str]) -> tuple[dict[str, dict[str, int]], dict[str, str]]:
    """Group members found by name in ~, and stale user files with their reasons.

    The walk goes NAME_SEARCH_DEPTH directories deep and skips symlinks, other
    filesystems, git work trees, node_modules, and the paths in prune. A
    __pycache__ whose files have hard links elsewhere stays: removing it
    frees nothing.
    """
    found: dict[str, dict[str, int]] = {g: {} for g in (*GROUP_BY_NAME.values(), "group:pycache")}
    stale: dict[str, str] = {}
    now, dev = time.time(), os.lstat(HOME).st_dev
    stack = [(HOME, 0)]
    while stack:
        top, depth = stack.pop()
        try:
            entries = list(os.scandir(top))
        except OSError:
            continue
        if top != HOME and any(e.name == ".git" for e in entries):
            continue
        for e in entries:
            try:
                st = e.stat(follow_symlinks=False)
            except OSError:
                continue
            if stat.S_ISLNK(st.st_mode) or st.st_dev != dev or e.path in prune:
                continue
            if stat.S_ISDIR(st.st_mode):
                if e.name == "__pycache__":
                    if (b := _pycache(e.path)) is not None:
                        found["group:pycache"][e.path] = b
                elif e.name != "node_modules" and depth < NAME_SEARCH_DEPTH:
                    stack.append((e.path, depth + 1))
                continue
            group = next((g for rx, g in GROUP_BY_NAME.items() if rx.fullmatch(e.name)), None)
            if group:
                if now - st.st_ctime >= JUNK[group].window:
                    found[group][e.path] = st.st_blocks * 512
            elif st.st_blocks * 512 >= FLOOR and now - st.st_ctime >= STALE and _user_file(e.path):
                stale[e.path] = f"unchanged since {day(st.st_ctime)}; nothing rebuilds it; {TRASH_SUFFIX}"
    return found, stale


def _pycache(path: str) -> int | None:
    """Allocated bytes in a __pycache__, or None when a file there has another link."""
    total = 0
    try:
        for e in os.scandir(path):
            st = e.stat(follow_symlinks=False)
            if st.st_nlink > 1 and not stat.S_ISDIR(st.st_mode):
                return None
            total += st.st_blocks * 512
    except OSError:
        return None
    return total


def _user_file(path: str) -> bool:
    return ((os.path.dirname(path) == HOME or any(inside(path, d) for d in USER_DIRS))
            and not inside(path, f"{HOME}/Desktop/workspace"))


def claude_own(path: str) -> bool:
    return os.path.dirname(path) == CLAUDE_TMP and os.path.basename(path).startswith("-")


def du_size(path: str) -> int:
    """Allocated bytes under path on its filesystem; du exits 1 after an unreadable directory and still prints."""
    proc = subprocess.run(["du", "-sx", "-B1", path], capture_output=True, text=True, check=False)
    if not proc.stdout:
        raise CommandError(f"`du` on {path}: {proc.stderr.strip()[-200:]}")
    return int(proc.stdout.split()[0])
