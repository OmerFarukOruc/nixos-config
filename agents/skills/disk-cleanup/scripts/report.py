"""The Markdown the survey prints, and the full list it writes."""

import os

from config import LEAVE_CAP, LOOK_CAP, SCAN
from docker import BOUND_NOTE
from filesystems import filesystem
from holders import HOME, tilde
from rows import Row, run, size


def pool_line(docker_root: str | None) -> str:
    """One sentence per filesystem that holds ~, /tmp, /var/tmp, /nix, or the Docker root."""
    groups: dict[str, list[str]] = {}
    for p in (HOME, "/tmp", "/var/tmp", "/nix", docker_root):
        if p and os.path.exists(p):
            groups.setdefault(filesystem(p).dev_id, []).append(p)
    lines = []
    for paths in groups.values():
        fs = filesystem(paths[0])
        used, avail = run(["df", "-B1", "--output=used,avail", fs.mount]).splitlines()[1].split()
        names = ", ".join(f"`{tilde(p)}`" for p in paths)
        lines.append(f"`df` shows {size(int(used))} used and {size(int(avail))} free on the `{fs.type}` filesystem "
                     f"at `{fs.mount}`, which {names} {'share' if len(paths) > 1 else 'uses'}.")
    return " ".join(lines)


def bounded(b: int, bound: bool) -> str:
    return f"up to {size(b)}" if bound else size(b)


def frees_cell(r: Row) -> str:
    return f"{size(r.frees)} in 7 days" if r.how == "tmp-trash" else bounded(r.frees, r.bound)


def table(rows: list[Row], kind: str, cap: int | None) -> list[str]:
    if not rows:
        return ["None."]
    sized = [r for r in rows if r.alloc]
    shown, hidden = (sized[:cap], sized[cap:]) if cap else (sized, [])
    shown += [r for r in rows if not r.alloc]
    if kind == "delete":
        lines = ["| Path | Frees | Comes back |", "| --- | --- | --- |"]
        lines += [f"| {r.label()} | {frees_cell(r)} | {r.reason} |" for r in shown]
    else:
        lines = ["| Path | Allocated | Why |", "| --- | --- | --- |"]
        lines += [f"| {r.label()} | {size(r.alloc) if r.alloc else '-'} | {r.reason} |" for r in shown]
    if hidden:
        lines += ["", f"{len(hidden)} more {kind} rows, {size(sum(r.alloc for r in hidden))} in total."]
    return lines


def full_table(rows: list[Row]) -> list[str]:
    lines = ["| List | Path | Allocated | Exclusive | Shared | Frees | Why |",
             "| --- | --- | --- | --- | --- | --- | --- |"]
    for r in rows:
        extra = " | ".join(size(x) if x is not None else "-" for x in (r.excl, r.shared, r.frees))
        lines.append(f"| {r.kind} | {r.label()} | {size(r.alloc)} | {extra} | {r.reason} |")
    for r in rows:
        if r.members is not None:
            lines += ["", f"## {r.path}", "", f"| Path | {'Frees' if r.kind == 'delete' else 'Allocated'} |",
                      "| --- | --- |"]
            lines += [f"| `{tilde(p)}` | {size(b)} |" for p, b in sorted(r.members.items(), key=lambda m: -m[1])]
    return lines


def proposal(lists: dict[str, list[Row]], pool: str, locked: list[str], unreadable: list[str],
             updates_section: list[str], full: str) -> str:
    """The Markdown the survey prints: the opening, the three tables, and what could not be read."""
    total = sum(r.frees for r in lists["delete"] if not r.bound and r.how != "tmp-trash")
    later = sum(r.frees for r in lists["delete"] if r.how == "tmp-trash")
    bound = sum(r.frees for r in lists["delete"] if r.bound)
    biggest = lists["look"][0] if lists["look"] else None
    count = len(lists["delete"])
    opening = f"Deleting the {count} delete row{'' if count == 1 else 's'} frees about {size(total)}"
    opening += f", plus up to {size(bound)} from Docker" if bound else ""
    opening += f", and {size(later)} more 7 days later from `/tmp` folders that go to the Trash first." if later else "."
    if biggest and biggest.alloc > total + bound:
        opening += f" The largest look row, {biggest.label()}, holds {size(biggest.alloc)}."
    compressed = any(filesystem(p).zstd_level is not None for p in SCAN)
    report = [opening, pool, "",
              "## Delete", "",
              "Frees is the expected `df` drop."
              + (" Allocated, below, counts bytes before compression." if compressed else ""),
              *([BOUND_NOTE] if bound else []), "",
              *table(lists["delete"], "delete", None), "",
              "## Look", "", *table(lists["look"], "look", LOOK_CAP), "",
              "## Leave", "", *table(lists["leave"], "leave", LEAVE_CAP), "",
              f"Needs a password, not measured: {', '.join(f'`{p}`' for p in locked)}."]
    if unreadable:
        parents = sorted({tilde(os.path.dirname(p)) for p in unreadable})
        report.append(f"{len(unreadable)} directories were unreadable, so sizes under "
                      f"{', '.join(f'`{p}`' for p in parents[:3])} are low.")
    if updates_section:
        report += ["", *updates_section, ""]
    report.append(f"Full list: `{full}`.")
    return "\n".join(report)
