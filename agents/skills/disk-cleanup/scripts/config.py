"""The floor, the windows, the directories, and the class tables every survey module reads.

references/choices.md holds the reason for each window and path set.
"""

import os
import re
import tempfile
from typing import NamedTuple

from holders import HOME
from learn import load_tables

FLOOR = 100 * 2**20
LOOK_CAP, LEAVE_CAP = 10, 8
SCAN = [HOME, "/tmp", "/var/tmp"]
CLAUDE_TMP = f"/tmp/claude-{os.getuid()}"
AGENTS_TMP = "/tmp/agents"
TMP_DIRS = ("/tmp", "/var/tmp", CLAUDE_TMP, AGENTS_TMP)
GROUP_DIRS = {HOME, *TMP_DIRS} | {
    f"{HOME}/{d}"
    for d in (".cache", ".config", ".local", ".local/share", ".local/state",
              "Desktop", "Desktop/workspace", "Documents")
}
RECENT = 24 * 3600
STALE = 30 * 86400
BUILD_TREES = (f"{HOME}/Desktop", "/tmp", "/var/tmp")


class BuildOutput(NamedTuple):
    marker: str
    comes_back: str
    window: int


BUILD_OUTPUT = {
    "node_modules": BuildOutput("package.json", "the project's install command, such as `pnpm install`", RECENT),
    "target": BuildOutput("Cargo.toml", "the next `cargo build`", 0),
}


class Area(NamedTuple):
    window: int
    why: str


# The tmpfiles ages are the `q` lines of tmp.conf in `systemd-tmpfiles --cat-config`.
AREAS = {
    f"{HOME}/.cache": Area(STALE, "an app rebuilds its cache"),
    "/tmp": Area(RECENT, "tmpfiles deletes it after 10 days"),
    "/var/tmp": Area(RECENT, "tmpfiles deletes it after 30 days"),
    CLAUDE_TMP: Area(RECENT, "tmpfiles deletes it after 10 days"),
    AGENTS_TMP: Area(RECENT, "tmpfiles deletes it after 10 days"),
}
TRASH_SUFFIX = "Trash when named"
TRASH_DIR = f"{HOME}/.local/share/Trash"
TRASH_AGE = 7 * 86400


class Junk(NamedTuple):
    kind: str
    window: int
    how: str
    reason: str


JUNK = {
    "group:stale-cache": Junk("delete", STALE, "rm", "unchanged 30+ days; an app rebuilds its cache"),
    "group:stale-tmp": Junk("delete", RECENT, "rm",
                            "files of yours, unchanged 24+ h; tmpfiles would delete them anyway"),
    "group:stale-tmp-dirs": Junk("delete", RECENT, "tmp-trash",
                                 "folders of yours, unchanged 24+ h; to the Trash, which frees them 7 days later"),
    "group:tmp-trash": Junk("delete", TRASH_AGE, "trash-purge",
                            "`/tmp` folders disk-cleanup moved to the Trash 7+ days ago"),
    "group:empty-dirs": Junk("delete", RECENT, "rmdir", "in `~/.cache`, `/tmp`, `/var/tmp`; tidiness only"),
    "group:downloads": Junk("delete", RECENT, "rm", "incomplete downloads unchanged 24+ h; the download starts over"),
    "group:pycache": Junk("delete", 0, "rm", "outside git work trees; Python rebuilds them on import"),
    "group:swap": Junk("look", 0, "trash", f"editor swap files; one can hold unsaved text; {TRASH_SUFFIX}"),
    "group:backups": Junk("look", 0, "trash", f"`*~` and `*.bak` backups; {TRASH_SUFFIX}"),
}
GROUP_BY_NAME = {
    re.compile(r".+\.(crdownload|part)"): "group:downloads",
    re.compile(r"\..+\.sw[nop]|#.+#"): "group:swap",
    re.compile(r".+~|.+\.bak"): "group:backups",
}
NAME_SEARCH_DEPTH = 12
UNFINISHED_DEPTH = 3
BACKUP_HOME = re.compile(re.escape(f"{HOME}/backups/") + r"(?:[^/]+/)*?home/(.+)")
USER_DIRS = [f"{HOME}/Downloads", f"{HOME}/Documents", f"{HOME}/Desktop"]
HANDOFFS = f"{HOME}/handoffs"
OUT_DIR = os.path.join(tempfile.gettempdir(), "disk-cleanup")
RUNTIME_PREFIXES = ("systemd-private-", ".X11-unix", "pulse-")
NEEDS_PASSWORD = ["/var/log", "/var/cache"]
NIX_STORE = "/nix/store"
# What git's is_git_directory() checks.
GIT_DIR = {"HEAD", "objects", "refs"}

TABLES = load_tables()
DELETE, DELETE_BY_COMMAND, LEAVE = TABLES["delete"], TABLES["delete_by_command"], TABLES["leave"]
BACKUP_DELETE, BACKUP_TRASH = TABLES["backup_delete"], TABLES["backup_trash"]
