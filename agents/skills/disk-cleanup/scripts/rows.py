"""One row of the proposal, the size and date formats, and the command runner."""

import dataclasses
import subprocess
import time

from holders import tilde


def size(b: int) -> str:
    if b >= 2**30:
        return f"{b / 2**30:.1f} GiB"
    if b >= 2**20:
        return f"{b // 2**20} MiB"
    return f"{b // 1024} KiB"


def day(t: float) -> str:
    return time.strftime("%d-%m-%Y", time.localtime(t))


class CommandError(Exception):
    pass


def run(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=120, check=True).stdout
    except subprocess.CalledProcessError as e:
        raise CommandError(f"`{' '.join(cmd[:3])}` failed: {e.stderr.strip()[-200:]}") from e
    except (OSError, subprocess.SubprocessError) as e:
        raise CommandError(f"`{cmd[0]}`: {e}") from e


@dataclasses.dataclass
class Row:
    """One row of the survey; survey.json holds these fields for remove.py.

    path is a filesystem path, a group such as "group:stale-cache", or a label such as "Docker images".
    kind is delete, look, or leave. window is the seconds a path must stay unchanged before it goes
    (see config.RECENT). how is a key of remove.COMMANDS or remove.MOVERS. members holds a group's
    entries with Frees, or size on look, and is None for one path. excl, shared, and frees are set for
    rows the reclaim estimate ran on, and inodes counts the inodes it counted, for learn.py. rest means
    alloc excludes rows nested inside this path. changed is the newest ctime under the path, for delete
    rows. bound means frees is an upper bound, not an estimate.
    """

    path: str
    kind: str
    reason: str
    window: int = 0
    how: str = "rm"
    members: dict[str, int] | None = None
    alloc: int = 0
    excl: int | None = None
    shared: int | None = None
    frees: int | None = None
    inodes: int = 0
    rest: bool = False
    fs_type: str = ""
    changed: float | None = None
    bound: bool = False

    def label(self) -> str:
        if self.members is not None:
            return f"`{tilde(self.path)}` ({len(self.members)} entries)"
        name = f"`{tilde(self.path)}`" if self.path.startswith("/") else self.path
        return name + (" (rest)" if self.rest else "")

    def targets(self) -> dict[str, int]:
        """What remove.py removes for this row, each with its Frees."""
        return self.members if self.members is not None else {self.path: self.frees or 0}
