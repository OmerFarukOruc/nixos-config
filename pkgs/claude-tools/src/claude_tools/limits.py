from __future__ import annotations

import re
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

NO_RESET_WAIT = 3600
TAIL = 6
LIMIT = re.compile(r"You've hit your (session|weekly) limit · resets (.+?\))")
MODEL_LIMIT = re.compile(r"You've reached your \S+ limit")
MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
RESET = re.compile(
    r"(?:(?P<mon>[A-Z][a-z]{2}) (?P<day>\d{1,2}), )?(?P<h>\d{1,2})(?::(?P<m>\d{2}))?(?P<ap>am|pm) \((?P<tz>[^)]+)\)"
)


def find_limit(screen: str) -> dict | None:
    lines = screen.splitlines()
    end = len(lines)
    for i in range(len(lines) - 1, 0, -1):
        if lines[i].lstrip().startswith("❯") and lines[i - 1].lstrip().startswith("─"):
            end = i - 1
            break
    for line in reversed([x for x in lines[:end] if x.strip()][-TAIL:]):
        if m := LIMIT.search(line):
            return {"kind": m[1], "reset": m[2]}
        if MODEL_LIMIT.search(line):
            return {"kind": "model", "reset": None}
    return None


def parse_reset(text: str, now: datetime) -> float | None:
    m = RESET.fullmatch(text.strip())
    if not m:
        return None
    try:
        local = now.astimezone(ZoneInfo(m["tz"]))
    except (ZoneInfoNotFoundError, ValueError):
        return None
    hour = int(m["h"]) % 12 + (12 if m["ap"] == "pm" else 0)
    at = {"hour": hour, "minute": int(m["m"] or 0), "second": 0, "microsecond": 0}
    try:
        if m["mon"]:
            t = local.replace(month=MONTHS.index(m["mon"]) + 1, day=int(m["day"]), **at)
            if t < local - timedelta(days=180):
                t = t.replace(year=t.year + 1)
        else:
            t = local.replace(**at)
            if t <= local:
                t += timedelta(days=1)
    except ValueError:
        return None
    return t.timestamp()


def active(limits: dict, now: float) -> dict:
    return {n: v for n, v in limits.items() if v.get("until", 0) > now}


def mark(limits: dict, account: str, until: float | None, reason: str, now: float) -> None:
    limits[account] = {"until": until or now + NO_RESET_WAIT, "reason": reason}


def limited_until(entry: dict | None, now: float) -> tuple[float, str]:
    for key, label in (("seven_day", "weekly"), ("five_hour", "session")):
        w = (entry or {}).get(key)
        if w and w["used"] >= 100 and w.get("resets_at"):
            return w["resets_at"], f"{label} limit"
    return now + NO_RESET_WAIT, "limit with no full window"
