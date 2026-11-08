"""Turn measured paths into delete, look, and leave rows, and move a row when a check fails."""

import functools
import os
import stat
import subprocess
import time
from collections.abc import Iterable

from activity import unfinished
from config import (
    AREAS,
    BACKUP_DELETE,
    BACKUP_HOME,
    BACKUP_TRASH,
    BUILD_OUTPUT,
    BUILD_TREES,
    DELETE,
    DELETE_BY_COMMAND,
    FLOOR,
    GROUP_DIRS,
    JUNK,
    LEAVE,
    RECENT,
    RUNTIME_PREFIXES,
    SCAN,
    STALE,
    TRASH_AGE,
    TRASH_DIR,
    TRASH_SUFFIX,
)
from filesystems import mount_points
from holders import HOME, Hit, inside, tilde
from learn import trashed
from measure import claude_own, lstat_tree, reclaim, walk_tree
from rows import Row, day, size


def own_class(path: str, links: list[str]) -> Row | None:
    """The row for the class path matches, or None."""
    key = tilde(path)
    if key in DELETE:
        return Row(path, "delete", DELETE[key])
    if key in DELETE_BY_COMMAND:
        return Row(path, "delete", DELETE_BY_COMMAND[key], window=RECENT)
    if key in LEAVE:
        return Row(path, "leave", LEAVE[key])
    if m := BACKUP_HOME.fullmatch(path):
        if m[1] in BACKUP_DELETE:
            return Row(path, "delete", f"in a backed-up home: {BACKUP_DELETE[m[1]]}")
        if m[1] in BACKUP_TRASH:
            return Row(path, "look", f"in a backed-up home: {BACKUP_TRASH[m[1]]}; {TRASH_SUFFIX}", how="trash")
    name, parent = os.path.basename(path), os.path.dirname(path)
    if (name in BUILD_OUTPUT and any(inside(parent, w) for w in BUILD_TREES)
            and "node_modules" not in parent.split("/")
            and os.path.exists(f"{parent}/{BUILD_OUTPUT[name].marker}")):
        _, reason, window = BUILD_OUTPUT[name]
        return Row(path, "delete", reason, window=window)
    if os.path.basename(parent) == "versions":
        live = [t for t in links if inside(t, parent)]
        if any(inside(t, path) for t in live):
            return Row(path, "leave", "the version a command in `~/.local/bin` runs")
        if live:
            return Row(path, "delete", "a reinstall of that version", window=RECENT)
        return Row(path, "look", "no command in `~/.local/bin` points into this `versions/`")
    if parent.endswith("/.slim/clonedeps/repos"):
        return Row(path, "look", "clonedeps repo; delete it by hand only when it is gitignored "
                                 "and the app imports the package from outside the clone")
    if parent == f"{HOME}/Desktop/workspace" and os.path.exists(f"{path}/.git"):
        return Row(path, "leave", "work; `node_modules/` and `target/` inside can still go")
    if parent in ("/tmp", "/var/tmp") and name.startswith(RUNTIME_PREFIXES):
        return Row(path, "leave", "runtime directory")
    if claude_own(path):
        return Row(path, "leave", "Claude Code's task output for one project")
    return None


def bin_links() -> list[str]:
    """Where each symlink in ~/.local/bin resolves."""
    return [os.path.realpath(e.path) for e in os.scandir(f"{HOME}/.local/bin") if e.is_symlink()]


def owner(path: str, rows: dict[str, Row]) -> Row | None:
    while path not in SCAN and path != "/":
        path = os.path.dirname(path)
        if path in rows:
            return rows[path]
    return None


def group_child(path: str) -> str:
    while os.path.dirname(path) not in GROUP_DIRS:
        path = os.path.dirname(path)
    return path


def build_rows(sizes: dict[str, int], stale_files: dict[str, str]) -> dict[str, Row]:
    """Disjoint rows: each measured path belongs to exactly one row."""
    links = bin_links()
    rows: dict[str, Row] = {}
    for path in sorted(sizes, key=lambda p: p.count("/")):
        if path in GROUP_DIRS:
            continue
        up = owner(path, rows)
        if up and up.kind == "delete":
            continue
        if path in stale_files and not (up and up.kind == "leave"):
            rows[path] = Row(path, "look", stale_files[path], window=STALE, how="trash")
            continue
        row = own_class(path, links)
        exact_delete = tilde(path) in DELETE or tilde(path) in DELETE_BY_COMMAND
        blocked = up and tilde(up.path) in LEAVE and not exact_delete
        if row and not blocked:
            rows[path] = row
        elif up is None and group_child(path) == path:
            rows[path] = Row(path, "look", "unlisted")
    for path, row in rows.items():
        nested = [p for p in rows if owner(p, rows) is row]
        row.alloc = sizes[path] - sum(sizes[p] for p in nested)
        row.rest = bool(nested)
        if row.reason == "unlisted":
            row.reason = ", ".join(filter(None, ["unlisted", largest_part(path, sizes)]))
    return {p: r for p, r in rows.items() if r.alloc >= FLOOR}


def note_sqlite(sizes: dict[str, int], rows: dict[str, Row]) -> None:
    """Name the SQLite files on a look or leave row with free pages at or above the floor."""
    notes: dict[str, list[str]] = {}
    for path in sizes:
        row = rows.get(path) or owner(path, rows)
        if row and row.kind != "delete" and (free := sqlite_free(path)) >= FLOOR:
            name = os.path.relpath(path, row.path) if path != row.path else os.path.basename(path)
            notes.setdefault(row.path, []).append(f"`{name}` ({size(free)})")
    for path, files in notes.items():
        rows[path].reason += f"; VACUUM with the app closed returns the free pages in {' and '.join(files)}"


def sqlite_free(path: str) -> int:
    """Free-page bytes from a SQLite file's header, or 0 for any other file.

    The main file's header lags a WAL until the app checkpoints, which is close
    enough for a note, and the survey opens no database connection. Offsets:
    https://www.sqlite.org/fileformat.html#the_database_header
    """
    try:
        with open(path, "rb") as f:
            head = f.read(40)
    except OSError:
        return 0
    if not head.startswith(b"SQLite format 3\0"):
        return 0
    page = int.from_bytes(head[16:18], "big")  # 1 stands for 65536
    return (65536 if page == 1 else page) * int.from_bytes(head[36:40], "big")


def largest_part(path: str, sizes: dict[str, int]) -> str:
    """Follow the largest child while it holds at least half of path."""
    node = path
    while True:
        big = max((p for p in sizes if os.path.dirname(p) == node), key=sizes.get, default=None)
        if big is None or sizes[big] * 2 < sizes[path]:
            break
        node = big
    return "" if node == path else f"mostly `{os.path.relpath(node, path)}` ({size(sizes[node])})"


def junk_rows(rows: dict[str, Row], stale: list[tuple[str, float, int]], empties: list[str],
              found: dict[str, dict[str, int]], leaves: set[str]) -> list[Row]:
    """Turn stale entries at or above the floor into delete rows, and group the rest.

    A group member inside a delete row or a leave path, or a protected one,
    drops out. A stale entry that holds a row stays out of the groups, so the
    row's bytes count once.
    """
    members = {g: dict(ps) for g, ps in found.items()}
    members["group:empty-dirs"] = dict.fromkeys(empties, 0)
    for g in ("group:stale-cache", "group:stale-tmp", "group:stale-tmp-dirs"):
        members[g] = {}
    entries = {os.path.join(a, os.path.relpath(r, a).split(os.sep)[0])
               for r in rows for a in AREAS if inside(r, a) and r != a}
    for path, changed, alloc in stale:
        window, why = AREAS[os.path.dirname(path)]
        row = rows.get(path)
        folder = not inside(path, HOME) and os.path.isdir(path) and not os.path.islink(path)
        busy = folder and unfinished(path)
        if row is None:
            if path not in entries and not busy:
                group = ("group:stale-cache" if inside(path, HOME)
                         else "group:stale-tmp-dirs" if folder else "group:stale-tmp")
                members[group][path] = alloc
        elif row.kind == "look" and row.reason.startswith("unlisted") and not row.rest and not busy:
            row.kind, row.window, row.reason = "delete", window, f"unchanged since {day(changed)}; {why}"
            if folder:
                row.how, row.reason = "tmp-trash", f"{row.reason}; to the Trash, which frees it 7 days later"
    dels = [r.path for r in rows.values() if r.kind == "delete" and r.path.startswith("/")]
    out = []
    for group, paths in members.items():
        keep = {p: b for p, b in paths.items()
                if not any(inside(p, d) for d in (*dels, *leaves)) and not protected(p, leaves)}
        if keep:
            kind, window, how, reason = JUNK[group]
            out.append(Row(group, kind, reason, window=window, how=how, members=keep))
    return out


def trash_entries() -> dict[str, bool]:
    """Each entry in the Trash, and whether remove.py moved it there from /tmp."""
    moved = trashed()
    try:
        return {f"{TRASH_DIR}/files/{n}": n in moved for n in os.listdir(f"{TRASH_DIR}/files")}
    except OSError:
        return {}


def split_trash(rows: dict[str, Row], sizes: dict[str, int]) -> None:
    """The Trash delete row offers each entry except the ones remove.py moved from /tmp.

    trash_rows() offers those once they have been there TRASH_AGE, so the
    Trash row leaves the 7-day hold intact. trash-purge removes an entry
    with its .trashinfo file.
    """
    row = rows.get(TRASH_DIR)
    if not row or row.kind != "delete":
        return
    row.members = {p: sizes.get(p, 0) for p, moved in trash_entries().items() if not moved}
    row.how, row.alloc = JUNK["group:tmp-trash"].how, sum(row.members.values())
    if not row.members:
        del rows[TRASH_DIR]


def trash_rows() -> list[Row]:
    """The Trash entries remove.py moved from /tmp that have been there TRASH_AGE.

    The rename or copy that took them there set the entry's ctime, so its
    newest ctime is the move; nothing else in the Trash is offered.
    """
    now, old = time.time(), {}
    for path, moved in trash_entries().items():
        if moved and now - (tree := walk_tree(path)).changed >= TRASH_AGE:
            old[path] = tree.alloc
    if not old:
        return []
    _, window, how, reason = JUNK["group:tmp-trash"]
    return [Row("group:tmp-trash", "delete", reason, window=window, how=how, members=old)]


def leave_paths(rows: Iterable[Row], scanned_root: str | None) -> set[str]:
    """The LEAVE table's paths, every leave row that is a path, and the scanned Docker root."""
    return ({os.path.expanduser(k) for k in LEAVE}
            | {r.path for r in rows if r.kind == "leave" and r.path.startswith("/")}
            | ({scanned_root} if scanned_root else set()))


def scanned_docker_root(root: str | None) -> str | None:
    """The Docker root when a scan root holds it, else None."""
    return root if root and any(inside(root, top) for top in SCAN) else None


def protected(path: str, leaves: set[str]) -> str | None:
    """Why path stays whatever its class says, or None."""
    real = os.path.realpath(path)
    if os.path.islink(path):
        return "a symlink"
    if not any(inside(real, top) for top in SCAN):
        return "outside ~, /tmp, and /var/tmp"
    if real in GROUP_DIRS:
        return f"`{tilde(real)}` itself"
    if kept := next((p for p in leaves if inside(p, real)), None):
        return f"holds the leave path `{tilde(kept)}`"
    if mount := next((m for m in mount_points() if inside(m, real)), None):
        return f"`{tilde(mount)}` is a mount point"
    return None


@functools.cache
def trash_dev() -> int:
    return os.stat(TRASH_DIR if os.path.isdir(TRASH_DIR) else os.path.dirname(TRASH_DIR)).st_dev


def not_yours(path: str, how: str) -> str | None:
    if not path.startswith("/") or how not in ("rm", "tmp-trash", "trash-purge"):
        return None
    uid, parent = os.getuid(), os.path.dirname(path)
    try:
        top, up = os.lstat(path), os.lstat(parent)
    except OSError:
        return None
    if up.st_uid != uid and not os.access(parent, os.W_OK | os.X_OK):
        return parent
    copies = how == "tmp-trash" and top.st_dev != trash_dev()
    sticky = {parent} if up.st_mode & stat.S_ISVTX and up.st_uid != uid else set()
    for entry, st, names in lstat_tree(path):
        if st.st_uid == uid or stat.S_ISLNK(st.st_mode):
            continue
        folder = stat.S_ISDIR(st.st_mode)
        if (os.path.dirname(entry) in sticky
                or folder and (names is None or names and not os.access(entry, os.W_OK | os.X_OK))
                or copies and not os.access(entry, os.R_OK | (os.X_OK if folder else 0))):
            return entry
        if folder and st.st_mode & stat.S_ISVTX:
            sticky.add(entry)
    return None


def demote_used(cands: list[Row], held: dict[str, list[Hit]], leaves: set[str]) -> None:
    """A delete row that is protected, in use, or holds another user's entry moves to look."""
    for r in cands:
        if why := protected(r.path, leaves):
            r.kind, r.reason = "look", f"protected: {why}"
        elif held[r.path]:
            r.kind, r.reason = "look", in_use(held[r.path][0])
        elif blocked := next(filter(None, (not_yours(p, r.how) for p in r.targets())), None):
            r.kind, r.reason = "look", f"`{tilde(blocked)}` belongs to another user; remove it with sudo"


def in_use(hit: Hit) -> str:
    verb = {"cwd": "works in it", "exe": "runs from it", "fd": "holds a file in it",
            "map": "maps a file from it", "arg": "was started with a path in it",
            "browser": "is running"}.get(hit.how, f"has it in ${hit.how[4:]}")
    return f"in use: `{hit.name}` (pid {hit.pid}) {verb}"


def recent(changed: float, window: int, verb: str = "changed") -> str | None:
    """The reason a path that changed inside window stays, else None."""
    if time.time() - changed >= window:
        return None
    return f"{verb} {time.strftime('%d-%m %H:%M', time.localtime(changed))}; work may still use it"


def estimate(cands: list[Row]) -> None:
    """Set each delete row's expected drop; a group's is the sum of its paths'.

    A path row that frees little moves to leave; one changed inside its
    window, to look.
    """
    paths = [list(r.targets()) for r in cands]
    got = iter(reclaim([p for ps in paths for p in ps]))
    for r, ps in zip(cands, paths, strict=True):
        parts = [next(got) for _ in ps]
        r.excl, r.shared, r.frees, r.inodes = (sum(g[i] for g in parts) for i in range(4))
        r.changed = max(g.changed for g in parts)
        types = {g.fs.type for g in parts}
        r.fs_type = types.pop() if len(types) == 1 else "mixed"
        if r.members is not None:
            r.members = {p: g.frees for p, g in zip(ps, parts, strict=True)}
        elif r.frees < FLOOR:
            fs = parts[0].fs
            cause = (f"{size(r.shared)} is shared with other files" if r.shared > r.excl
                     else f"`{fs.type}` stores its {size(r.excl)} compressed" if fs.zstd_level is not None
                     else f"only {size(r.excl)} is its own")
            r.kind, r.reason = "leave", f"frees only {size(r.frees)}: {cause}"
        elif r.window and (reason := recent(r.changed, r.window)):
            r.kind, r.reason = "look", reason


def date_tmp(tmp: list[Row], held: dict[str, list[Hit]]) -> None:
    """A /tmp or /var/tmp row's reason is its birth date and its user."""
    if not tmp:
        return
    # stat exits 1 after a path removed since the scan and still prints the others.
    out = subprocess.run(["stat", "-c", "%W %n", *[r.path for r in tmp]],
                         capture_output=True, text=True, check=False).stdout
    born = dict(line.split(" ", 1)[::-1] for line in out.splitlines())
    for r in tmp:
        when = day(int(born[r.path])) if r.path in born else "on an unknown date"
        who = f"`{held[r.path][0].name}`" if held[r.path] else "no process"
        r.reason = f"created {when}; {who} uses it"
        if why := unfinished(r.path):
            r.reason += f"; {why}"
