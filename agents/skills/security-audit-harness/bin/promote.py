#!/usr/bin/env python3
"""Trusted parent-side promotion of predeclared scratch files into an agent's artifacts/.

Usage: python3 -I promote.py --run DIR <agent-id> <scratch-relative-path>...

Reads agents/<id>/promotion.json (written by the parent before the agent ran) for the
allowlist and byte limits, and records the scratch root's device and inode captured
when the scratch was created. Follows SKILL.md "Write isolation" steps 1-11.
"""
import json
import os
import re
import stat
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import runcfg

OUT = runcfg.OUT
ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
DEVICES = {"con", "prn", "aux", "nul"} | {f"com{i}" for i in range(1, 10)} | {f"lpt{i}" for i in range(1, 10)}
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


class Refused(Exception):
    pass


def components(rel):
    if not rel or rel.startswith("/") or "\0" in rel:
        raise Refused("absolute or empty path")
    parts = rel.split("/")
    for p in parts:
        if p in ("", ".", ".."):
            raise Refused(f"bad component {p!r}")
    return parts


def walk_without_following_links(root_fd, parts, create):
    fd = os.dup(root_fd)
    try:
        for p in parts:
            try:
                nfd = os.open(p, DIR_FLAGS, dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    raise Refused(f"missing directory {p!r}")
                os.mkdir(p, 0o700, dir_fd=fd)
                nfd = os.open(p, DIR_FLAGS, dir_fd=fd)
            except OSError as e:
                raise Refused(f"component {p!r} is not a real directory: {e.strerror}")
            st = os.fstat(nfd)
            if not stat.S_ISDIR(st.st_mode):
                os.close(nfd)
                raise Refused(f"component {p!r} is not a directory")
            os.close(fd)
            fd = nfd
        return fd
    except BaseException:
        os.close(fd)
        raise


def open_root(path, expect=None):
    fd = os.open(path, DIR_FLAGS)
    st = os.fstat(fd)
    if expect and (st.st_dev, st.st_ino) != (expect["dev"], expect["ino"]):
        os.close(fd)
        raise Refused(f"root {path} identity changed since setup")
    return fd


def promote_one(sfd, afd, rel, per_file, remaining):
    parts = components(rel)
    src_dir = walk_without_following_links(sfd, parts[:-1], create=False)
    try:
        try:
            src = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=src_dir)
        except OSError as e:
            raise Refused(f"cannot open leaf no-follow: {e.strerror}")
    finally:
        os.close(src_dir)
    try:
        st1 = os.fstat(src)
        if not stat.S_ISREG(st1.st_mode):
            raise Refused("not a regular file")
        if st1.st_nlink != 1:
            raise Refused(f"link count {st1.st_nlink}")
        limit = min(per_file, remaining)
        if st1.st_size > limit:
            raise Refused(f"size {st1.st_size} exceeds bound {limit}")
        data = bytearray()
        while len(data) <= st1.st_size:
            chunk = os.read(src, min(65536, st1.st_size + 1 - len(data)))
            if not chunk:
                break
            data += chunk
            if len(data) > limit:
                raise Refused("grew past bound while reading")
        st2 = os.fstat(src)
        if len(data) != st1.st_size or (st2.st_dev, st2.st_ino, st2.st_mode, st2.st_nlink, st2.st_size) != (
            st1.st_dev, st1.st_ino, st1.st_mode, st1.st_nlink, st1.st_size):
            raise Refused("file changed during copy")
        dst_dir = walk_without_following_links(afd, parts[:-1], create=True)
        try:
            try:
                dst = os.open(parts[-1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600,
                              dir_fd=dst_dir)
            except OSError as e:
                raise Refused(f"cannot create destination exclusively: {e.strerror}")
        finally:
            os.close(dst_dir)
        try:
            dst_st = os.fstat(dst)
            if not stat.S_ISREG(dst_st.st_mode) or dst_st.st_nlink != 1:
                raise Refused("destination is not a single-link regular file")
            view = memoryview(bytes(data))
            while view:
                n = os.write(dst, view)
                view = view[n:]
        finally:
            os.close(dst)
        return st1.st_size
    finally:
        os.close(src)


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    agent = sys.argv[1]
    if not ID_RE.match(agent) or agent in DEVICES:
        print(f"refused: unsafe agent id {agent!r}", file=sys.stderr)
        return 2
    base = os.path.join(OUT, "agents", agent)
    with open(os.path.join(base, "promotion.json"), "rb") as f:
        policy = json.load(f)
    allow = set(policy["allowlist"])
    sfd = open_root(os.path.join(base, "scratch"), policy.get("scratch_root"))
    afd = open_root(os.path.join(base, "artifacts"), policy.get("artifacts_root"))
    remaining = policy["cumulative_bytes"]
    rc = 0
    for rel in sys.argv[2:]:
        if rel not in allow:
            print(f"REFUSED {rel}: not in the predeclared allowlist")
            rc = 1
            continue
        try:
            n = promote_one(sfd, afd, rel, policy["per_file_bytes"], remaining)
            remaining -= n
            print(f"PROMOTED {rel} -> agents/{agent}/artifacts/{rel} ({n} bytes)")
        except Refused as e:
            print(f"REFUSED {rel}: {e}")
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
