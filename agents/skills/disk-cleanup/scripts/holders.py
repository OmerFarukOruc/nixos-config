#!/usr/bin/env python3
"""Print the processes that use each PATH.

One line per hit: "<PATH>: <pid> <name> <how> <target>". No lines means no
process uses any PATH. A process uses PATH when its cwd, its exe, an open fd, a mapped
file, a command-line argument, or an environment value points inside PATH,
or when PATH is a browser directory and that browser's binary runs.

A deleted file still counts: the process that holds it is a live user of the
tree, like `uv run` holding the cache lock. A process can run code from a
tree without holding a file there, like an `npx` server whose PATH points
into ~/.npm/_npx, so the environment counts too. Environment values can hold
secrets, so an environment hit prints the variable name only.
"""

import os
import re
import sys
from typing import NamedTuple

HOME = os.path.expanduser("~")
DELETED = " (deleted)"
# A directory the browser uses while it runs, then the pattern its running
# binary's path matches. The Nix store path holds the package name, such as
# `/nix/store/<hash>-brave-origin-1.97.59/opt/brave.com/brave-origin/brave`.
BROWSER_DIRS = {
    f"{HOME}/.cache/google-chrome": re.compile(r"/nix/store/[^/]+-google-chrome-"),
    f"{HOME}/.config/google-chrome/OptGuideOnDeviceModel": re.compile(r"/nix/store/[^/]+-google-chrome-"),
    f"{HOME}/.cache/BraveSoftware": re.compile(r"/nix/store/[^/]+-brave(-origin)?-"),
    f"{HOME}/.cache/mozilla": re.compile(r"/nix/store/[^/]+-firefox(-unwrapped)?-"),
}


class Hit(NamedTuple):
    """One use of a path: name is argv[0]'s basename, since Claude Code's comm is its version number.

    how is cwd, exe, fd, map, arg, browser, or "env NAME", and target is empty for an environment hit.
    """

    pid: str
    name: str
    how: str
    target: str

    def __str__(self) -> str:
        return f"{self.pid} {self.name} {self.how} {self.target}".rstrip()


def inside(target: str, root: str) -> bool:
    target = os.path.normpath(target.removesuffix(DELETED))
    return target == root or target.startswith(root + os.sep)


def tilde(path: str) -> str:
    return "~" + path[len(HOME):] if inside(path, HOME) else path


def _text(path: str) -> str:
    try:
        with open(path, "rb") as f:
            return f.read().decode(errors="replace")
    except OSError:
        return ""


def _refs(pid: str) -> list[tuple[str, str]]:
    """Every absolute path the process points at, as (how, target)."""
    base = f"/proc/{pid}"
    links = [("cwd", f"{base}/cwd"), ("exe", f"{base}/exe")]
    try:
        links += [("fd", f"{base}/fd/{fd}") for fd in os.listdir(f"{base}/fd")]
    except OSError:
        pass
    refs = []
    for how, link in links:
        try:
            refs.append((how, os.readlink(link)))
        except OSError:
            pass
    for line in _text(f"{base}/maps").splitlines():
        fields = line.split(maxsplit=5)
        if len(fields) == 6 and fields[5].startswith("/"):
            refs.append(("map", fields[5]))
    for arg in _text(f"{base}/cmdline").split("\0"):
        refs += [("arg", part.split()[0]) for part in arg.split("=") if part.startswith("/")]
    for entry in _text(f"{base}/environ").split("\0"):
        name, _, value = entry.partition("=")
        refs += [(f"env {name}", part) for part in value.split(":") if part.startswith("/")]
    return refs


def _name(pid: str) -> str:
    """argv[0]'s first word, since a process can rewrite argv[0] into a title."""
    words = _text(f"/proc/{pid}/cmdline").split("\0", 1)[0].split()
    return os.path.basename(words[0]) if words else _text(f"/proc/{pid}/comm").strip() or "?"


def _launchers() -> set[str]:
    """This process and its parents, whose arguments name the queried path."""
    pids, pid = set(), os.getpid()
    while pid > 1:
        pids.add(str(pid))
        # Fields after the "(comm)" are state, then ppid; an ancestor that exited leaves no record.
        fields = _text(f"/proc/{pid}/stat").rpartition(")")[2].split()
        if len(fields) < 2 or not fields[1].isdigit():
            break
        pid = int(fields[1])
    return pids


def users(paths: list[str]) -> dict[str, list[Hit]]:
    """Map each path to the processes that use it, scanning /proc once.

    Each target a process points at is looked up with its parent directories,
    so the cost grows with the number of targets, not with the number of paths.
    """
    by_root: dict[str, list[str]] = {}
    for path in paths:
        by_root.setdefault(os.path.realpath(path), []).append(path)
    browsers = {
        path: exe_pattern
        for root, same in by_root.items()
        for path in same
        for browser_dir, exe_pattern in BROWSER_DIRS.items()
        if inside(root, browser_dir)
    }
    hits: dict[str, list[Hit]] = {path: [] for path in paths}
    me, launchers = str(os.getpid()), _launchers()
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or pid == me:
            continue
        refs = _refs(pid)
        if pid in launchers:
            refs = [(how, target) for how, target in refs if how != "arg"]
        found: dict[str, tuple[str, str]] = {}
        for how, target in refs:
            node = os.path.normpath(target.removesuffix(DELETED))
            while node.startswith("/"):
                for path in by_root.get(node, ()):
                    found.setdefault(path, (how, target))
                if node == (node := os.path.dirname(node)):  # "/", or "//" kept by normpath
                    break
        exe = next((target for how, target in refs if how == "exe"), "")
        for path, exe_pattern in browsers.items():
            if path not in found and exe_pattern.match(exe):
                found[path] = ("browser", exe)
        if not found:
            continue
        name = _name(pid)
        for path, (how, target) in found.items():
            hits[path].append(Hit(pid, name, how, "" if how.startswith("env ") else target))
    return hits


def main() -> int:
    paths = sys.argv[1:]
    if not paths:
        print("usage: holders.py PATH...", file=sys.stderr)
        return 2
    missing = [p for p in paths if not os.path.lexists(p)]
    if missing:
        print(f"missing: {' '.join(missing)}", file=sys.stderr)
        return 2
    for path, hits in users(paths).items():
        for hit in hits:
            print(f"{path}: {hit}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
