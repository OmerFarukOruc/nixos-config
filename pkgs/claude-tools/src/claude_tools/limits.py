from __future__ import annotations

import fcntl
import re
import time
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from claude_tools.store import read_json, write_json

NO_RESET_WAIT = 3600
TAIL = 6
WINDOWS = {"five_hour": 5 * 3600, "seven_day": 7 * 86400}
LIMIT = re.compile(r"You've hit your (session|weekly) limit · resets (.+?\))")
MODEL_LIMIT = re.compile(r"You've reached your \S+ limit")
MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
RESET = re.compile(
    r"(?:(?P<mon>[A-Z][a-z]{2}) (?P<day>\d{1,2}), )?(?P<h>\d{1,2})(?::(?P<m>\d{2}))?(?P<ap>am|pm) \((?P<tz>[^)]+)\)"
)


def find_limit(screen: str) -> str | None:
    lines = screen.splitlines()
    end = len(lines)
    for i in range(len(lines) - 1, 0, -1):
        if lines[i].lstrip().startswith("❯") and lines[i - 1].lstrip().startswith("─"):
            end = i - 1
            break
    for line in reversed([x for x in lines[:end] if x.strip()][-TAIL:]):
        if parse_limit(line, int(time.time())):
            return line.strip()
    return None


def parse_reset(text: str, at: int, window: int) -> int | None:
    m = RESET.fullmatch(text.strip())
    if not m:
        return None
    try:
        local = datetime.fromtimestamp(at, ZoneInfo(m["tz"]))
    except (ZoneInfoNotFoundError, ValueError):
        return None
    clock = {"hour": int(m["h"]) % 12 + (12 if m["ap"] == "pm" else 0), "minute": int(m["m"] or 0), "second": 0,
             "microsecond": 0}
    try:
        if m["mon"]:
            t = local.replace(month=MONTHS.index(m["mon"]) + 1, day=int(m["day"]), **clock)
            if t.timestamp() <= at:
                t = t.replace(year=t.year + 1)
            if t.timestamp() - at > window:
                t = t.replace(year=t.year - 1)
        else:
            t = local.replace(**clock)
            if t.timestamp() <= at:
                t = (t + timedelta(days=1)).replace(**clock)
            if t.timestamp() - at > window:
                t = (t - timedelta(days=1)).replace(**clock)
    except ValueError:
        return None
    return int(t.timestamp())


def parse_limit(text: str, at: int) -> tuple[int | None, str] | None:
    if m := LIMIT.search(text):
        window = WINDOWS["five_hour" if m[1] == "session" else "seven_day"]
        return parse_reset(m[2], at, window), f"{m[1]} limit"
    if MODEL_LIMIT.search(text):
        return None, "model limit"
    return None


def full_window(e: dict, at: int) -> tuple[int, str] | None:
    windows = [(e.get("seven_day"), "weekly limit"), (e.get("five_hour"), "session limit"),
               *((x, f"{x['label']} limit") for x in e.get("scoped") or [])]
    return next(((w["resets_at"], reason) for w, reason in windows
                 if w and w["used"] >= 100 and (w.get("resets_at") or 0) > at), None)


def holds(path: Path, at: int) -> dict[str, dict]:
    data = read_json(path)
    return {n: v for n, v in (data.items() if isinstance(data, dict) else ())
            if isinstance(v, dict) and isinstance(v.get("until"), (int, float)) and v["until"] > at}


def hold(path: Path, name: str, until: int, reason: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.with_suffix(".lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        write_json(path, {**holds(path, int(time.time())), name: {"until": until, "reason": reason}})
