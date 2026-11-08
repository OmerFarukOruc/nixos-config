"""The filesystem under a path, and the `df` reading on a set of filesystems.

survey.py estimates each delete row's `df` drop from these facts, and
remove.py reads `df` on the filesystems a row's paths are on. Mounts come
from /proc/self/mountinfo, whose fields proc_pid_mountinfo(5) describes, and
btrfs metadata profiles from /sys/fs/btrfs, as
https://btrfs.readthedocs.io/en/latest/ch-sysfs.html describes.
"""

import functools
import glob
import os
import re
from typing import NamedTuple

from holders import inside
from learn import load_tables

# btrfs metadata profile, then the copies it keeps; btrfs(5), "Filesystem with
# multiple profiles". A profile not listed here counts 2.
METADATA_PROFILES = {"single": 1, "dup": 2, "raid1": 2, "raid10": 2, "raid1c3": 3, "raid1c4": 4}
ZSTD = re.compile(r"(?:^|,)compress(?:-force)?=zstd(?::(-?\d+))?(?:,|$)")


class Mount(NamedTuple):
    point: str
    dev_id: str
    type: str
    source: str
    super_options: str


@functools.cache
def mountinfo() -> tuple[Mount, ...]:
    """Every mount, in mount order."""
    def unescape(field: str) -> str:
        return re.sub(r"\\(\d{3})", lambda m: chr(int(m.group(1), 8)), field)
    out = []
    with open("/proc/self/mountinfo") as f:
        for line in f:
            fields = line.split()
            sep = fields.index("-")
            out.append(Mount(unescape(fields[4]), fields[2], *map(unescape, fields[sep + 1:sep + 4])))
    return tuple(out)


def mount_points() -> tuple[str, ...]:
    """Every mount point. /proc/self/mountinfo lists bind mounts too, which keep their source's st_dev."""
    return tuple(m.point for m in mountinfo())


class Fs(NamedTuple):
    mount: str
    type: str
    dev_id: str
    zstd_level: int | None
    metadata_copies: int
    inode_metadata: int
    # btrfs reports 4 KiB of st_blocks for a symlink whose target sits inline in its metadata.
    non_regular_blocks_are_data: bool


def filesystem(path: str) -> Fs:
    """The filesystem under path: the mount with the longest mount point above it, the last of equals."""
    real = os.path.realpath(path)
    return _filesystem(max(reversed([m for m in mountinfo() if m.point == "/" or inside(real, m.point)]),
                           key=lambda m: len(m.point)))


@functools.cache
def _filesystem(m: Mount) -> Fs:
    level = ZSTD.search(m.super_options)
    zstd_level = None if level is None else int(level[1] or 3)  # bare zstd is level 3
    copies = _btrfs_metadata_copies(m.source) if m.type == "btrfs" else 0
    return Fs(m.point, m.type, m.dev_id, zstd_level, copies, _inode_metadata().get(m.type, 0), m.type != "btrfs")


@functools.cache
def _inode_metadata() -> dict[str, int]:
    return load_tables()["inode_metadata"]


def _btrfs_metadata_copies(source: str) -> int:
    """The copies the metadata profiles of the btrfs filesystem on source keep, the largest of them; 2 when unknown."""
    dev = os.path.basename(os.path.realpath(source))
    for link in glob.glob(f"/sys/fs/btrfs/*/devices/{glob.escape(dev)}"):
        try:
            profiles = [e.name for e in os.scandir(f"{link.rpartition('/devices/')[0]}/allocation/metadata")
                        if e.is_dir()]
        except OSError:
            return 2
        return max((METADATA_PROFILES.get(p, 2) for p in profiles), default=2)
    return 2


def fs_mounts(paths: list[str]) -> list[str]:
    """One mount point for each filesystem that paths are on."""
    found: dict[str, str] = {}
    for p in paths:
        fs = filesystem(p)
        found.setdefault(fs.dev_id, fs.mount)
    return list(found.values())


def used(mounts: list[str]) -> int:
    """Bytes in use, summed over the filesystems at mounts, after a sync."""
    os.sync()
    return sum((st.f_blocks - st.f_bfree) * st.f_frsize for st in map(os.statvfs, mounts))
