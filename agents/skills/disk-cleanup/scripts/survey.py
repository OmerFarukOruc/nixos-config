#!/usr/bin/env python3
"""Measure disk use on this host and print the disk-cleanup proposal.

Prints Markdown: the pool line, then the delete, look, and leave tables, with
look and leave capped for a phone screen, then a "Skill updates" section when
a learn.py rule fires. Writes every row, uncapped, with allocated, exclusive,
shared, and expected-drop bytes and each group's paths, to
$TMPDIR/disk-cleanup/survey.md, the same rows as JSON to survey.json beside it
for remove.py, and a run record for learn.py. Reads only: du, /proc,
FIEMAP, which first writes a file's unwritten data to disk, SQLite file
headers, TASKS.md files, ~/handoffs files, git status and rev-list, docker
and its socket, Claude Code session files, the system profile links,
/sys/fs/btrfs, stat, and df.

A delete row's "Frees" is the expected `df` drop, from the facts of the
filesystem each path is on (filesystem()). `du` and `btrfs filesystem du`
count a compressed extent at its uncompressed size, so on a zstd mount the
estimate compresses each compressed extent again at the mount's zstd level
in 128 KiB chunks. Extents shared with another file, reflink, or snapshot
free nothing, and neither does a file with a hard link outside the path. On
btrfs, metadata counts too: inline file data plus the type's inode_metadata
bytes per inode, times the copies its metadata profile keeps, 2 for DUP.
ext4 allocates its inode tables at mkfs, so a delete there frees its file
data and directory blocks only.

A look or leave row names each SQLite file in it whose free pages, the space
a VACUUM returns, reach the floor.

A group row, such as `group:stale-cache`, gathers the paths under the floor
that one rule finds; remove.py checks and removes each of them on its own.
"""

import dataclasses
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor

from classify import (
    build_rows,
    date_tmp,
    demote_used,
    estimate,
    junk_rows,
    leave_paths,
    not_yours,
    note_sqlite,
    scanned_docker_root,
    split_trash,
    trash_rows,
)
from config import (
    AREAS,
    DELETE,
    DELETE_BY_COMMAND,
    LEAVE,
    NEEDS_PASSWORD,
    OUT_DIR,
    TMP_DIRS,
)
from docker import docker, docker_root_rows
from holders import HOME, inside, users
from host_rows import boot_rows, brave_rows, nix_rows, side_rows
from learn import record, section, updates
from measure import area_walk, name_walk, scan
from report import full_table, pool_line, proposal


def main() -> int:
    dock = docker()
    root = scanned_docker_root(dock.root)
    prune = ({os.path.expanduser(k) for k in (*DELETE, *DELETE_BY_COMMAND, *LEAVE)}
             | {a for a in AREAS if inside(a, HOME)} | ({root} if root else set()))
    with ThreadPoolExecutor(max_workers=7) as pool:
        side = [pool.submit(side_rows, label, f) for label, f in (
            ("Docker", dock.source), ("Nix store", nix_rows),
            ("Boot", boot_rows), ("Brave", brave_rows))]
        header = pool.submit(pool_line, dock.root)
        names = pool.submit(name_walk, prune)
        areas = pool.submit(area_walk)
        sizes, unreadable = scan()
        root_rows = docker_root_rows(sizes, root) if root else []
        found, stale_files = names.result()
        rows = build_rows(sizes, stale_files) | {r.path: r for r in root_rows}
        note_sqlite(sizes, rows)
        split_trash(rows, sizes)
        leaves = leave_paths(rows.values(), root)
        stale, empties = areas.result()
        groups = junk_rows(rows, stale, list(empties), found, leaves) + trash_rows()
        cands = [r for r in rows.values() if r.kind == "delete"]
        tmp = [r for r in rows.values()
               if r.kind == "look" and os.path.dirname(r.path) in TMP_DIRS]
        held = users([r.path for r in cands + tmp] + [p for g in groups for p in g.members]
                     + list(set(empties.values())))
        demote_used(cands, held, leaves)
        for g in groups:
            g.members = {p: b for p, b in g.members.items()
                         if not held[p] and not held.get(empties.get(p), ()) and not not_yours(p, g.how)}
            g.alloc = sum(g.members.values())
        groups = [g for g in groups if g.members]
        estimate([r for r in cands + groups if r.kind == "delete"])
        date_tmp(tmp, held)
    everything = list(rows.values()) + groups + [r for f in side for r in f.result()]
    lists = {k: sorted((r for r in everything if r.kind == k),
                       key=lambda r: -(r.frees if k == "delete" else r.alloc))
             for k in ("delete", "look", "leave")}
    others = [f"/home/{u}" for u in os.listdir("/home") if f"/home/{u}" != HOME]
    locked = NEEDS_PASSWORD + [p for p in others if not os.access(p, os.R_OK | os.X_OK)]

    generated = time.time()
    ordered = lists["delete"] + lists["look"] + lists["leave"]
    os.makedirs(OUT_DIR, exist_ok=True)
    full = os.path.join(OUT_DIR, "survey.md")
    with open(full, "w") as f:
        f.write("\n".join(full_table(ordered)) + "\n")
    with open(os.path.join(OUT_DIR, "survey.json"), "w") as f:
        json.dump({"generated": generated, "docker_host": dock.host, "docker_root": dock.root,
                   "rows": [dataclasses.asdict(r) for r in ordered]}, f)
    absent = [k for k in (*DELETE, *DELETE_BY_COMMAND, *LEAVE) if not os.path.lexists(os.path.expanduser(k))]
    record("survey", {"time": generated, "absent": absent,
                      "rows": [{"path": r.path, "kind": r.kind, "frees": r.frees} for r in ordered]})

    print(proposal(lists, header.result(), locked, unreadable, section(updates()), full))
    return 0


if __name__ == "__main__":
    sys.exit(main())
