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

# Some task stalled on memory for 300 ms within a 2 s window. A guess, not
# measured: an unprivileged trigger needs a window that is a multiple of 2 s,
# and 15% catches heavy swapping long before the kernel runs out of memory.
TRIGGER = b"some 300000 2000000\0"
# Both are guesses that keep the folder small: one snapshot holds a line of
# up to about 230 bytes per process, so about 1.4 MB with 6000 processes.
MIN_GAP = 60
KEEP = 100
TOP_GROUPS = 20
TOP_CGROUPS = 30
CMDLINE_MAX = 200


def state_dir():
    base = os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state"
    path = Path(base) / "oom-snapshots"
    path.mkdir(parents=True, exist_ok=True)
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
    uid = os.getuid()
    root = Path(
        f"/sys/fs/cgroup/user.slice/user-{uid}.slice/user@{uid}.service"
    )
    rows = []
    for path, dirs, _ in os.walk(root):
        if dirs:
            continue
        values = []
        for name in ("memory.current", "memory.swap.current", "memory.peak"):
            text = read(Path(path) / name).strip()
            values.append(int(text) if text.isdigit() else 0)
        rows.append((values[0] + values[1], Path(path).name, *values))
    return sorted(rows, reverse=True)[:TOP_CGROUPS]


def snapshot():
    now = time.time()
    procs = processes()
    groups = defaultdict(lambda: [0, 0])
    for ppid, name, rss, swap, _ in procs.values():
        group = groups[(ppid, name)]
        group[0] += 1
        group[1] += rss + swap
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
        "Groups by parent: parent pid, child name, count, RSS+swap MiB,"
        " parent command line",
    ]
    ranked = sorted(groups.items(), key=lambda g: g[1][1], reverse=True)
    for (ppid, name), (count, total) in ranked[:TOP_GROUPS]:
        parent = procs.get(ppid, (0, "", 0, 0, "?"))[4]
        lines.append(f"{ppid} {name} {count} {total >> 10} {parent}")
    lines += [
        "",
        "Leaf user cgroups: current+swap MiB, name, current, swap, peak MiB",
    ]
    for total, name, cur, swap, peak in leaf_cgroups():
        lines.append(
            f"{total >> 20} {name} {cur >> 20} {swap >> 20} {peak >> 20}"
        )
    lines += ["", "Processes: pid, ppid, RSS KiB, swap KiB, command line"]
    for pid in sorted(procs, key=lambda p: procs[p][2] + procs[p][3],
                      reverse=True):
        ppid, _, rss, swap, cmd = procs[pid]
        lines.append(f"{pid} {ppid} {rss} {swap} {cmd}")
    folder = state_dir()
    path = folder / f"{stamp}.txt"
    tmp = path.with_suffix(".tmp")
    tmp.write_text("\n".join(lines) + "\n")
    tmp.rename(path)
    for old in sorted(folder.glob("*.txt"))[:-KEEP]:
        old.unlink(missing_ok=True)
    top = ranked[0] if ranked else ((0, "?"), (0, 0))
    print(
        f"wrote {path}: {len(procs)} processes; largest group"
        f" {top[1][0]} x {top[0][1]} under pid {top[0][0]}",
        flush=True,
    )


def watch():
    fd = os.open("/proc/pressure/memory", os.O_RDWR | os.O_NONBLOCK)
    os.write(fd, TRIGGER)
    poller = select.poll()
    poller.register(fd, select.POLLPRI)
    last = 0.0
    print(f"watching /proc/pressure/memory: {TRIGGER[:-1].decode()}",
          flush=True)
    while True:
        for _, event in poller.poll():
            if event & select.POLLERR:
                sys.exit("memory-pressure-snapshot: the PSI trigger is gone")
            if event & select.POLLPRI and time.monotonic() - last >= MIN_GAP:
                last = time.monotonic()
                snapshot()


def main():
    if sys.argv[1:] == ["--once"]:
        snapshot()
    elif sys.argv[1:]:
        sys.exit("usage: memory-pressure-snapshot [--once]")
    else:
        watch()


if __name__ == "__main__":
    main()
