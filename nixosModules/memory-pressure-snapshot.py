# Writes a snapshot of every process and user cgroup when memory pressure
# rises, so an OOM kill that follows can be traced to the process that
# spawned the memory. The kernel's OOM task table names no parent and no
# command line, and the processes are gone by the time anyone looks.
#
#   memory-pressure-snapshot [--once]
#
# Without --once it waits on a PSI trigger on /proc/pressure/memory
# (Documentation/accounting/psi.rst) and writes at most one snapshot per
# MIN_GAP. --once writes one snapshot now and exits. Snapshots go to
# $XDG_STATE_HOME/oom-snapshots (default ~/.local/state/oom-snapshots).
import os
import select
import sys
import time
from collections import defaultdict
from pathlib import Path

# Some task stalled on memory for 300 ms (15%) within a 2 s window. The
# threshold is a guess, not measured. An unprivileged trigger needs a window
# that is a multiple of 2 s (psi.rst).
TRIGGER = b"some 300000 2000000\0"
# Guesses. A process line is at most about 230 bytes (a 200-character command
# line plus the numbers), so a snapshot of 6000 processes is about 1.4 MB and
# the folder at most about 140 MB. Under steady pressure the 100 files cover
# only the last 100 minutes.
MIN_GAP = 60
KEEP = 100
# Guesses at what fits on a screen.
TOP_GROUPS = 20
TOP_NAMES = 10
TOP_CGROUPS = 30
CMDLINE_MAX = 200


def state_dir():
    base = os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state"
    path = Path(base) / "oom-snapshots"
    # Command lines can hold tokens, so only the owner reads the snapshots.
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.chmod(0o700)
    return path


def read(path):
    try:
        return Path(path).read_text(errors="replace")
    except OSError:
        return ""


def kib(status, key):
    for line in status.splitlines():
        if line.startswith(key + ":"):
            return int(line.split()[1])
    return 0


def processes():
    """Returns {pid: (ppid, name, rss KiB, swap KiB, command line)}."""
    out = {}
    for entry in os.scandir("/proc"):
        if not entry.name.isdigit():
            continue
        status = read(f"/proc/{entry.name}/status")
        if not status:
            continue
        name = ppid = ""
        for line in status.splitlines():
            if line.startswith("Name:"):
                name = line.partition(":")[2].strip()
            elif line.startswith("PPid:"):
                ppid = line.split()[1]
        raw = read(f"/proc/{entry.name}/cmdline")
        cmd = raw.replace("\0", " ").replace("\n", "\\n").strip()
        cmd = cmd[:CMDLINE_MAX]
        out[int(entry.name)] = (
            int(ppid or 0),
            name,
            kib(status, "VmRSS"),
            kib(status, "VmSwap"),
            cmd or f"[{name}]",
        )
    return out


def leaf_cgroups():
    """Returns the largest leaf cgroups of this user, login sessions included,
    as (current+swap, path, current, swap, peak, tasks)."""
    root = Path(f"/sys/fs/cgroup/user.slice/user-{os.getuid()}.slice")
    rows = []
    for path, dirs, _ in os.walk(root):
        if dirs:
            continue
        values = []
        for name in ("memory.current", "memory.swap.current", "memory.peak",
                     "pids.current"):
            text = read(Path(path) / name).strip()
            values.append(int(text) if text.isdigit() else 0)
        rows.append((values[0] + values[1],
                     str(Path(path).relative_to(root)), *values))
    return sorted(rows, reverse=True)[:TOP_CGROUPS]


def snapshot():
    now = time.time()
    procs = processes()
    groups = defaultdict(lambda: [0, 0])
    names = defaultdict(lambda: [0, 0])
    for ppid, name, rss, swap, _ in procs.values():
        for row in (groups[(ppid, name)], names[name]):
            row[0] += 1
            row[1] += rss + swap
    meminfo = {
        line.split(":")[0]: line.split()[1]
        for line in read("/proc/meminfo").splitlines()
        if line.startswith(("MemAvailable:", "SwapFree:", "SwapTotal:"))
    }
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(now))
    lines = [
        f"snapshot {time.strftime('%Y-%m-%d %H:%M:%S %z')}",
        read("/proc/pressure/memory").strip(),
        " ".join(f"{k} {v} kB" for k, v in meminfo.items()),
        f"{len(procs)} processes",
        "",
        "Names by count: count, RSS+swap MiB, name (RSS counts shared pages"
        " once per process)",
    ]
    by_count = sorted(names.items(), key=lambda n: n[1], reverse=True)
    for name, (count, total) in by_count[:TOP_NAMES]:
        lines.append(f"{count} {total >> 10} {name!r}")
    lines += [
        "",
        "Groups by parent: parent pid, count, RSS+swap MiB, child name,"
        " parent command line",
    ]
    ranked = sorted(groups.items(), key=lambda g: g[1][1], reverse=True)
    for (ppid, name), (count, total) in ranked[:TOP_GROUPS]:
        parent = procs.get(ppid, (0, "", 0, 0, "?"))[4]
        lines.append(f"{ppid} {count} {total >> 10} {name!r} {parent}")
    lines += [
        "",
        "Leaf user cgroups: current+swap MiB, current, swap, peak MiB, tasks,"
        " path under the user slice",
    ]
    for total, path, cur, swap, peak, tasks in leaf_cgroups():
        lines.append(
            f"{total >> 20} {cur >> 20} {swap >> 20} {peak >> 20} {tasks}"
            f" {path}"
        )
    lines += ["", "Processes: pid, ppid, RSS KiB, swap KiB, command line"]
    for pid in sorted(procs, key=lambda p: procs[p][2] + procs[p][3],
                      reverse=True):
        ppid, _, rss, swap, cmd = procs[pid]
        lines.append(f"{pid} {ppid} {rss} {swap} {cmd}")
    folder = state_dir()
    path = folder / f"{stamp}.txt"
    tmp = path.with_suffix(".tmp")
    try:
        # An OOM often ends in a reset, so the file reaches the disk before
        # its name appears.
        with open(tmp, "w", encoding="utf-8", errors="replace") as f:
            f.write("\n".join(lines) + "\n")
            f.flush()
            os.fsync(f.fileno())
        tmp.rename(path)
    finally:
        tmp.unlink(missing_ok=True)
    for old in sorted(folder.glob("*.txt"))[:-KEEP]:
        old.unlink(missing_ok=True)
    top = ranked[0] if ranked else ((0, "?"), (0, 0))
    print(
        f"wrote {path}: {len(procs)} processes; largest group"
        f" {top[1][0]} x {top[0][1]} under pid {top[0][0]}",
        flush=True,
    )


def watch():
    # A folder that cannot be made fails here, at login, and not at the
    # first pressure event.
    state_dir()
    fd = os.open("/proc/pressure/memory", os.O_RDWR | os.O_NONBLOCK)
    os.write(fd, TRIGGER)
    poller = select.poll()
    poller.register(fd, select.POLLPRI)
    last = -MIN_GAP
    print(f"watching /proc/pressure/memory: {TRIGGER[:-1].decode()}",
          flush=True)
    while True:
        for _, event in poller.poll():
            if event & select.POLLERR:
                sys.exit("memory-pressure-snapshot: the PSI trigger is gone")
            if event & select.POLLPRI and time.monotonic() - last >= MIN_GAP:
                try:
                    snapshot()
                except OSError as e:
                    # A full disk now may have room at the next event.
                    print(f"memory-pressure-snapshot: {e}", file=sys.stderr,
                          flush=True)
                last = time.monotonic()


def main():
    if sys.argv[1:] == ["--once"]:
        snapshot()
    elif sys.argv[1:]:
        sys.exit("usage: memory-pressure-snapshot [--once]")
    else:
        watch()


if __name__ == "__main__":
    main()
