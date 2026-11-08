#!/usr/bin/env python3
"""Records of disk-cleanup runs, the rules that learn from them, and their edits.

survey.py and remove.py each write one record per real run to STATE_DIR
(`${XDG_STATE_HOME:-~/.local/state}/disk-cleanup`) and keep the newest KEEP
of each kind; the repository keeps no records. The
survey prints the "Skill updates" section that `learn.py check` prints. A
rule fires on this evidence. Its edit applies now when it only keeps more
data or changes no deletion, and asks Omer first when it allows more:

- estimate: 2 of the last 3 measured deletes on one filesystem type missed
  Frees (see missed()). Applies now: that type's inode_metadata refit by
  least squares, when the refit value brings all 3 within the miss.
  Otherwise no edit fits, and the rows need a look.
- skipped: Omer left the same delete row out in 3 runs where he named rows,
  counted since the last run that named it.
  Applies now: a leave entry.
- unlisted: Omer named the same unlisted path in 2 delete runs. Asks: a
  delete entry, with the agent's reason for how its bytes come back.
- absent: an overlay entry's path was missing in the last 5 surveys, which
  span ABSENT_SPAN. Applies now for delete entries: a prune. Asks for leave
  and delete_by_command entries, since a path that comes back would lose
  its protection or its command. A tables.json entry stays: a path missing
  on one host says nothing about another.

tables.json is the baseline every host shares, and only a person edits it.
The rules see it merged with this host's overlay, STATE_DIR/tables.<hostname>.json,
whose entries win (load_tables). The overlay stays on its host and never goes
into the repository. Edits change the overlay only, never tables.json or a
check in holders.py or remove.py. Each prints its diff:

    learn.py leave PATH REASON
    learn.py delete PATH REASON [--by-command]
    learn.py prune PATH...
    learn.py inode-metadata TYPE BYTES

`learn.py decline` followed by an asked edit's arguments keeps that edit's
paths quiet.
"""

import argparse
import difflib
import json
import os
import shlex
import socket
import sys
import tempfile
import time
from collections import Counter
from typing import NamedTuple

from holders import HOME, tilde

STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME") or f"{HOME}/.local/state", "disk-cleanup")
SCRIPTS = os.path.dirname(os.path.abspath(__file__))
TABLES = os.path.join(SCRIPTS, "tables.json")
OVERLAY = os.path.join(STATE_DIR, f"tables.{socket.gethostname()}.json")
CLASSES = ("delete", "delete_by_command", "leave")
KEEP = 20
MISS = 0.05
NOISE = 2 * 2**20
ABSENT_SPAN = 30 * 86400


def missed(frees: int, drop: int) -> bool:
    """Whether a measured drop misses the estimate by more than MISS and NOISE."""
    return abs(drop - frees) > max(MISS * frees, NOISE)


def load_tables() -> dict:
    """tables.json merged with this host's overlay; an overlay key leaves its tables.json class."""
    with open(TABLES) as f:
        tables = json.load(f)
    overlay = load_overlay()
    for c in CLASSES:
        for key, reason in overlay.get(c, {}).items():
            for other in CLASSES:
                tables[other].pop(key, None)
            tables[c][key] = reason
    tables["inode_metadata"] |= overlay.get("inode_metadata", {})
    return tables


def load_overlay() -> dict:
    """This host's overlay alone, empty when it has none."""
    try:
        with open(OVERLAY) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def record(kind: str, data: dict) -> None:
    """Write one run's record, then keep the newest KEEP of its kind."""
    os.makedirs(STATE_DIR, exist_ok=True)
    atomic_write(os.path.join(STATE_DIR, f"{kind}-{time.time_ns()}.json"), json.dumps(data))
    for name in _names(kind)[:-KEEP]:
        os.remove(os.path.join(STATE_DIR, name))


def _names(kind: str) -> list[str]:
    try:
        names = os.listdir(STATE_DIR)
    except OSError:
        return []
    stamps = [n[len(kind) + 1:-5] for n in names if n.startswith(f"{kind}-") and n.endswith(".json")]
    return [f"{kind}-{s}.json" for s in sorted((s for s in stamps if s.isdigit()), key=int)]


def records(kind: str) -> list[dict]:
    """Every kept record of kind, oldest first."""
    out = []
    for name in _names(kind):
        with open(os.path.join(STATE_DIR, name)) as f:
            out.append(json.load(f))
    return out


def trashed() -> dict[str, str]:
    """Each Trash entry name remove.py moved there from /tmp or /var/tmp, then its original path."""
    try:
        with open(os.path.join(STATE_DIR, "trashed.json")) as f:
            return json.load(f)
    except OSError:
        return {}


def write_trashed(names: dict[str, str]) -> None:
    os.makedirs(STATE_DIR, exist_ok=True)
    atomic_write(os.path.join(STATE_DIR, "trashed.json"), json.dumps(names))


def _declined() -> set[str]:
    try:
        with open(os.path.join(STATE_DIR, "declined.json")) as f:
            return set(json.load(f))
    except OSError:
        return set()


class Update(NamedTuple):
    """One fired rule: its name (estimate, skipped, unlisted, or absent), the evidence, and the edit.

    edit holds the learn.py arguments, empty when no edit fits.
    """

    rule: str
    asks: bool
    evidence: str
    edit: str


def updates() -> list[Update]:
    """Every rule that fires on the kept records. A declined path stays quiet."""
    tables, surveys, deletes, declined = load_tables(), records("survey"), records("delete"), _declined()
    listed = {k for c in CLASSES for k in tables[c]}
    return [*_estimate(deletes, tables["inode_metadata"]),
            *_skipped(deletes, surveys, set(tables["leave"])),
            *_unlisted(deletes, listed | _quiet(declined, "unlisted")),
            *_absent(surveys, load_overlay(), _quiet(declined, "absent"))]


def _quiet(declined: set[str], rule: str) -> set[str]:
    """The paths Omer declined for rule."""
    return {k.removeprefix(f"{rule}:") for k in declined if k.startswith(f"{rule}:")}


def _mib(b: int) -> str:
    return f"{b / 2**20:.0f} MiB"


def _paths(keys: list[str]) -> str:
    shown = ", ".join(f"`{k}`" for k in keys[:3])
    return shown + (f", and {len(keys) - 3} more" if len(keys) > 3 else "")


def _estimate(deletes: list[dict], current: dict[str, int]) -> list[Update]:
    """One update per filesystem type whose last 3 measured deletes missed twice; an unlisted type counts 0."""
    types = sorted({r["fs_type"] for d in deletes for r in d["rows"] if r.get("fs_type") not in (None, "", "mixed")})
    return [u for fs in types if (u := _estimate_type(deletes, fs, current.get(fs, 0)))]


def _estimate_type(deletes: list[dict], fs: str, current: int) -> Update | None:
    rows = [r for d in deletes for r in d["rows"]
            if r.get("measured") and r.get("fs_type") == fs and r["inode_metadata"] == current][-3:]
    if len(rows) < 3 or sum(missed(r["frees"], r["drop"]) for r in rows) < 2:
        return None
    scale = _meta_scale(rows)
    fit = round(current * scale)
    fits = fit > 0 and not any(missed(r["frees"] - r["meta"] + round(r["meta"] * scale), r["drop"]) for r in rows)
    evidence = "; ".join(f"`{tilde(r['path'])}` Frees {_mib(r['frees'])}, drop {_mib(r['drop'])}" for r in rows)
    return Update("estimate", False, f"2 of the last 3 `{fs}` deletes missed: {evidence}",
                  f"inode-metadata {fs} {fit}" if fits else "")


def _meta_scale(rows: list[dict]) -> float:
    """The least-squares factor that scales each row's meta so Frees meets the drop.

    Frees is the rest plus meta, and meta scales with inode_metadata, so the
    factor is sum(meta * (drop - rest)) / sum(meta^2).
    """
    den = sum(r["meta"] ** 2 for r in rows)
    return sum(r["meta"] * (r["drop"] - (r["frees"] - r["meta"])) for r in rows) / den if den else 0


def _skipped(deletes: list[dict], surveys: list[dict], leave: set[str]) -> list[Update]:
    now = {r["path"] for r in surveys[-1]["rows"] if r["kind"] == "delete"} if surveys else set()
    counts: Counter[str] = Counter()
    for d in deletes:
        for r in d["rows"]:
            counts.pop(r["path"], None)
        if d["named"]:
            counts.update(d["skipped"])
    return [Update("skipped", False, f"Omer left `{tilde(p)}` out in {n} runs where he named rows",
                   f"leave {shlex.quote(tilde(p))} 'Omer keeps it'")
            for p, n in counts.items() if n >= 3 and p in now and tilde(p) not in leave]


def _unlisted(deletes: list[dict], quiet: set[str]) -> list[Update]:
    runs = Counter(p for d in deletes for p in {r["path"] for r in d["rows"] if r["refused"] and r["unlisted"]}
                   if p.startswith("/"))
    return [Update("unlisted", True, f"Omer named `{tilde(p)}` in {n} delete runs, and no table lists it",
                   f"delete {shlex.quote(tilde(p))} REASON")
            for p, n in runs.items() if n >= 2 and tilde(p) not in quiet]


def _absent(surveys: list[dict], overlay: dict, quiet: set[str]) -> list[Update]:
    last = surveys[-5:]
    if len(last) < 5 or last[-1]["time"] - last[0]["time"] < ABSENT_SPAN:
        return []
    gone = set.intersection(*(set(s["absent"]) for s in last)) - quiet
    days = int((last[-1]["time"] - last[0]["time"]) // 86400)
    out = []
    for asks in (False, True):
        keys = [k for c in CLASSES for k in overlay.get(c, {}) if k in gone and (c != "delete") == asks]
        if keys:
            out.append(Update("absent", asks, f"{_paths(keys)} missing in the last 5 surveys, over {days} days",
                              "prune " + " ".join(shlex.quote(k) for k in keys)))
    return out


def section(found: list[Update]) -> list[str]:
    """The Skill updates section, or nothing when no rule fired."""
    if not found:
        return []
    lines = ["## Skill updates", "", "| Rule | Evidence | Edit |", "| --- | --- | --- |"]
    for u in found:
        edit = f"{'asks' if u.asks else 'applies now'}: `learn.py {u.edit}`" if u.edit else "none fits"
        lines.append(f"| {u.rule} | {u.evidence} | {edit} |")
    return lines


def atomic_write(path: str, text: str) -> None:
    """Write path with one rename, keeping the mode of the file it replaces."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=f".{os.path.basename(path)}.")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    if os.path.exists(path):
        os.chmod(tmp, os.stat(path).st_mode & 0o777)
    os.replace(tmp, path)


def edit(change) -> None:
    """Apply change to this host's overlay, write it back, and print the diff."""
    try:
        with open(OVERLAY) as f:
            before = f.read()
    except FileNotFoundError:
        before = ""
    overlay = json.loads(before) if before else {}
    change(overlay)
    overlay = {k: v for k, v in overlay.items() if v != {}}
    after = json.dumps(overlay, indent=2, ensure_ascii=False) + "\n" if overlay else ""
    if overlay:
        os.makedirs(STATE_DIR, exist_ok=True)
        atomic_write(OVERLAY, after)
    elif os.path.exists(OVERLAY):
        os.remove(OVERLAY)
    load_tables()
    name = os.path.basename(OVERLAY)
    sys.stdout.writelines(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                                               f"a/{name}", f"b/{name}"))


def main() -> int:
    parser = argparse.ArgumentParser(description="Print or apply disk-cleanup skill updates.")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check", help="print the Skill updates section")
    for name in ("leave", "delete"):
        p = sub.add_parser(name)
        p.add_argument("path")
        p.add_argument("reason")
    sub.choices["delete"].add_argument("--by-command", action="store_true")
    sub.add_parser("prune").add_argument("paths", nargs="+")
    meta = sub.add_parser("inode-metadata")
    meta.add_argument("type")
    meta.add_argument("bytes", type=int)
    sub.add_parser("decline", help="the arguments of an asked edit Omer turned down").add_argument("edit", nargs="+")
    args = parser.parse_args()

    if args.cmd == "check":
        print("\n".join(section(updates())) or "No skill updates.")
        return 0
    if args.cmd == "decline":
        verb, *rest = args.edit
        rule = {"prune": "absent", "delete": "unlisted"}[verb]
        keys = {f"{rule}:{_key(p)}" for p in (rest if verb == "prune" else rest[:1])}
        os.makedirs(STATE_DIR, exist_ok=True)
        atomic_write(os.path.join(STATE_DIR, "declined.json"), json.dumps(sorted(keys | _declined())))
        print("declined " + " ".join(sorted(keys)))
        return 0
    if args.cmd == "inode-metadata":
        edit(lambda t: t.setdefault("inode_metadata", {}).update({args.type: args.bytes}))
        return 0

    keys = [_key(p) for p in args.paths] if args.cmd == "prune" else [_key(args.path)]
    overlay = load_overlay()
    missing = [k for k in keys if not any(k in overlay.get(c, {}) for c in CLASSES)]
    if args.cmd == "prune" and missing:
        print(f"not in {os.path.basename(OVERLAY)}: {' '.join(missing)}; tables.json changes by hand",
              file=sys.stderr)
        return 2
    target = {"leave": "leave", "delete": "delete_by_command" if getattr(args, "by_command", False) else "delete"}

    def change(overlay: dict) -> None:
        for key in keys:
            for c in CLASSES:
                overlay.get(c, {}).pop(key, None)
            if args.cmd in target:
                overlay.setdefault(target[args.cmd], {})[key] = args.reason

    edit(change)
    return 0


def _key(path: str) -> str:
    """A path as the tables write it: under ~ with a tilde."""
    return tilde(os.path.abspath(os.path.expanduser(path)))


if __name__ == "__main__":
    sys.exit(main())
