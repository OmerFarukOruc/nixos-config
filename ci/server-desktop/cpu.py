import json
import os
import sys
import time

CLK = os.sysconf("SC_CLK_TCK")


def machine_ticks():
    """Returns busy, steal and all ticks. Steal is time that the host gave to
    other work while this VM wanted a CPU, so it counts as neither."""
    fields = [int(v) for v in open("/proc/stat").readline().split()[1:]]
    user, nice, system, idle, iowait, irq, softirq, steal = fields[:8]
    busy = user + nice + system + irq + softirq
    return busy, steal, busy + steal + idle + iowait


def process_ticks():
    ticks = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            raw = open(f"/proc/{pid}/stat").read()
        except OSError:
            continue
        name = raw[raw.index("(") + 1 : raw.rindex(")")]
        rest = raw[raw.rindex(")") + 2 :].split()
        ticks[(pid, name)] = int(rest[11]) + int(rest[12])
    return ticks


seconds = float(sys.argv[1])
busy0, steal0, total0 = machine_ticks()
procs0 = process_ticks()
start = time.monotonic()
time.sleep(seconds)
elapsed = time.monotonic() - start
busy1, steal1, total1 = machine_ticks()
procs1 = process_ticks()

by_name = {}
for key, ticks in procs1.items():
    delta = ticks - procs0.get(key, 0)
    by_name[key[1]] = by_name.get(key[1], 0) + delta
top = sorted(by_name.items(), key=lambda item: -item[1])[:6]
print(
    json.dumps(
        {
            "seconds": round(elapsed, 1),
            "busy_cores": round((busy1 - busy0) / (total1 - total0) * os.cpu_count(), 2),
            "steal_cores": round((steal1 - steal0) / (total1 - total0) * os.cpu_count(), 2),
            "top": {name: round(ticks / CLK / elapsed, 2) for name, ticks in top},
        }
    )
)
