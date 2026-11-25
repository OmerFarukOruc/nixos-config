from __future__ import annotations

import json
import os
import re
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from claude_tools.store import locked, now, read_json, write_json
from claude_tools.usage import epoch

NO_RESET_WAIT = 3600
TRANSCRIPT_TAIL = 256 * 1024
WINDOWS = {"five_hour": 5 * 3600, "seven_day": 7 * 86400}
LIMIT = re.compile(r"You've (?:hit|reached) your (?:(?P<window>session|5-hour|weekly)|(?P<model>[A-Z][\w.]*(?: [\d.]+)?)) "
                   r"limit(?: · resets (?P<reset>.+?\)))?")
MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
RESET = re.compile(
    r"(?:(?P<mon>[A-Z][a-z]{2}) (?P<day>\d{1,2}), )?(?P<h>\d{1,2})(?::(?P<m>\d{2}))?(?P<ap>am|pm) \((?P<tz>[^)]+)\)"
)


def assistant_entries(transcript: Path) -> Iterator[dict]:
    with transcript.open("rb") as f:
        size = f.seek(0, os.SEEK_END)
        f.seek(max(0, size - TRANSCRIPT_TAIL))
        lines = f.read().splitlines()
    for line in reversed(lines):
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict) and entry.get("type") == "assistant":
            yield entry


def last_assistant(transcript: Path) -> dict | None:
    return next(assistant_entries(transcript), None)


def last_model(projects: Path, session: str) -> str | None:
    transcript = next(projects.glob(f"*/{session}.jsonl"), None)
    try:
        for entry in assistant_entries(transcript) if transcript else ():
            model = (entry.get("message") or {}).get("model")
            if isinstance(model, str) and model and not model.startswith("<"):
                return model
    except OSError:
        return None
    return None


def recorded_limit(projects: Path, session: str) -> tuple[str, int] | None:
    transcript = next(projects.glob(f"*/{session}.jsonl"), None)
    try:
        entry = last_assistant(transcript) if transcript else None
    except OSError:
        return None
    if not entry or entry.get("isApiErrorMessage") is not True or entry.get("apiError") != "usage_limit_reached":
        return None
    try:
        text = " ".join(c.get("text") or "" for c in entry["message"]["content"]).strip()
        said = epoch(entry["timestamp"])
    except (AttributeError, KeyError, TypeError, ValueError):
        return None
    return (text, said) if said else None


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

    def step(t: datetime, n: int) -> datetime:
        return t.replace(year=t.year + n) if m["mon"] else (t + timedelta(days=n)).replace(**clock)

    try:
        t = local.replace(**clock, **({"month": MONTHS.index(m["mon"]) + 1, "day": int(m["day"])} if m["mon"] else {}))
        if t.timestamp() <= at:
            t = step(t, 1)
        if t.timestamp() - at > window:
            t = step(t, -1)
    except ValueError:
        return None
    return int(t.timestamp())


def parse_limit(text: str, at: int) -> tuple[int | None, str, str | None] | None:
    m = LIMIT.search(text)
    if not m:
        return None
    what = m["window"] or m["model"]
    window = WINDOWS["five_hour" if what in ("session", "5-hour") else "seven_day"]
    return parse_reset(m["reset"], at, window) if m["reset"] else None, f"{what} limit", m["model"]


def covers(label: str, model: str | None) -> bool:
    return bool(model) and label.split()[0].lower() in model.lower()


def full_window(e: dict, at: int, model: str | None = None) -> tuple[int, str, str | None] | None:
    scoped = [(x, f"{x['label']} limit", x["label"]) for x in e.get("scoped") or []
              if model is None or covers(x["label"], model)]
    windows = scoped if model else [(e.get("seven_day"), "weekly limit", None), (e.get("five_hour"), "session limit", None),
                                    *scoped]
    return next(((w["resets_at"], reason, label) for w, reason, label in windows
                 if w and w["used"] >= 100 and (w.get("resets_at") or 0) > at), None)


@dataclass(frozen=True)
class Hold:
    account: str
    until: int
    reason: str
    model: str | None = None

    @property
    def key(self) -> str:
        return f"{self.account}:{self.model}" if self.model else self.account

    def json(self) -> dict:
        return {"until": self.until, "reason": self.reason, **({"model": self.model} if self.model else {})}

    def blocks(self, model: str | None) -> bool:
        return self.model is None or covers(self.model, model)


def holds(path: Path, at: int) -> list[Hold]:
    found = []
    for key, v in read_json(path).items():
        if not isinstance(v, dict) or not isinstance(v.get("until"), (int, float)) or v["until"] <= at:
            continue
        model = v["model"] if isinstance(v.get("model"), str) and key.endswith(f":{v['model']}") else None
        found.append(Hold(key.removesuffix(f":{model}") if model else key, int(v["until"]), str(v.get("reason") or ""),
                          model))
    return found


def hold(path: Path, new: Hold) -> Hold:
    with locked(path.with_suffix(".lock")):
        write_json(path, {**{h.key: h.json() for h in holds(path, now())}, new.key: new.json()})
    return new
