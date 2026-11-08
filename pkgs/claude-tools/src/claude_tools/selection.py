from __future__ import annotations

import math
import re

from claude_tools.accounts import accounts
from claude_tools.limits import NO_RESET_WAIT, WINDOWS, full_window, hold, holds, parse_limit
from claude_tools.settings import Settings
from claude_tools.store import now
from claude_tools.usage import by_name, entries, locked_refresh

SESSION_MAX, WEEK_MAX = 90, 95
EVEN_BURN = {key: 100 / (length / 3600) for key, length in WINDOWS.items()}
MIN_ELAPSED = {"five_hour": 900, "seven_day": WINDOWS["five_hour"]}
REFRESH_BUDGET = 120
RECENT = 60
FIRST, LASTS, SHORT, BLOCKED = range(4)
GROUPS = ("first", "lasts", "short", "blocked")
CAPS = (("five_hour", SESSION_MAX), ("seven_day", WEEK_MAX))
LABELS = {"five_hour": "5h", "seven_day": "7d"}


def span(seconds: float) -> str:
    seconds = int(seconds)
    d, h, m = seconds // 86400, seconds % 86400 // 3600, seconds % 3600 // 60
    return f"{d}d {h}h" if d else f"{h}h {m}m" if h else f"{m}m"


def size(plan: str | None) -> float:
    m = re.search(r"(\d+)x", plan or "")
    return int(m[1]) / 5 if m else 1


def window_now(w: dict | None, at: int) -> tuple[float, int | None]:
    if not w or not w.get("resets_at") or w["resets_at"] <= at:
        return 0.0, None
    return w["used"], w["resets_at"]


def burn(readings: list[dict], key: str, at: int) -> float:
    total = 0.0
    for e in readings:
        w, checked = e.get(key), e.get("checked")
        if not w or not checked or not w.get("resets_at") or w["resets_at"] <= at:
            continue
        elapsed = WINDOWS[key] - (w["resets_at"] - checked)
        if elapsed >= MIN_ELAPSED[key]:
            total += w["used"] * size(e.get("plan")) / (elapsed / 3600)
    return max(total, EVEN_BURN[key])


def readable(e: dict) -> bool:
    return e.get("state") in ("ok", "expiring") and bool(e.get("five_hour") or e.get("seven_day"))


def blocked(e: dict, held: bool, at: int) -> str | None:
    if e.get("state") == "logged-out":
        return "logged out"
    if held:
        return "held back after a limit"
    if not e.get("five_hour") and not e.get("seven_day"):
        return "no reading yet"
    if not readable(e):
        return "usage unreadable"
    for key, cap in CAPS:
        used = window_now(e.get(key), at)[0]
        if used >= cap:
            return f"{LABELS[key]} at {used:.0f}%"
    return None


def runs_out(e: dict, key: str, cap: int, rate: float, at: int) -> float:
    used, reset = window_now(e.get(key), at)
    seconds = (cap - used) * size(e.get("plan")) / rate * 3600
    return seconds if reset and seconds < reset - at else math.inf


def place(e: dict, rates: dict[str, float], at: int) -> tuple[tuple, str]:
    lasts_for = {key: runs_out(e, key, cap, rates[key], at) for key, cap in CAPS}
    out = min(lasts_for, key=lasts_for.get)
    five_reset, week_reset = window_now(e.get("five_hour"), at)[1], window_now(e.get("seven_day"), at)[1]
    lasts = lasts_for[out] >= (five_reset or at + WINDOWS["five_hour"]) - at
    short = "" if lasts else f"{LABELS[out]} limit in about {span(lasts_for[out])}"
    if week_reset and lasts_for["seven_day"] == math.inf:
        week = window_now(e["seven_day"], at)[0]
        return ((FIRST, not lasts, week_reset),
                f"{WEEK_MAX - week:.0f}% of the week unused, resets in {span(week_reset - at)}"
                + (f" · {short}" if short else ""))
    if short:
        return (SHORT, -lasts_for[out]), short
    if five_reset:
        why = f"lasts to its 5h reset in {span(five_reset - at)}"
    elif e.get("five_hour"):
        why = "5h window not started"
    else:
        why = f"week resets in {span(week_reset - at)}" if week_reset else "week not started"
    return (LASTS, week_reset or at + WINDOWS["seven_day"]), why


def order(readings: dict[str, dict], names: list[str], held: set[str], at: int) -> list[tuple[str, int, str]]:
    rates = {key: burn(list(readings.values()), key, at) for key in WINDOWS}
    places = []
    for i, n in enumerate(names):
        e = readings.get(n) or {}
        if why := blocked(e, n in held, at):
            places.append(((BLOCKED, i), n, why))
        else:
            key, why = place(e, rates, at)
            places.append((key, n, why))
    return [(n, key[0], why) for key, n, why in sorted(places)]


def held_names(settings: Settings) -> set[str]:
    return set(holds(settings.holds_file, now()))


def ranked(settings: Settings, readings: dict[str, dict], names: list[str]) -> list[tuple[str, int, str]]:
    return order(readings, names, held_names(settings), now())


def startable(settings: Settings, readings: dict[str, dict], names: list[str]) -> list[str]:
    return [n for n, g, _ in ranked(settings, readings, names) if g != BLOCKED]


def best(settings: Settings, readings: dict[str, dict], names: list[str]) -> str | None:
    return next(iter(startable(settings, readings, names)), None)


def next_account(settings: Settings, skip: str | None) -> str | None:
    names = [n for n in accounts(settings.accounts_file) if n != skip]
    at, readings = now(), entries(settings)
    held = holds(settings.holds_file, at)
    fresh = [n for n in names if n not in held and at - ((readings.get(n) or {}).get("checked") or 0) > RECENT]
    if fresh:
        data = locked_refresh(settings, fresh, RECENT, at + REFRESH_BUDGET)
        readings = by_name(data)
    return best(settings, readings, names)


def free_at(settings: Settings, names: list[str], at: int) -> int | None:
    readings, held = entries(settings), holds(settings.holds_file, at)
    times = []
    for n in names:
        e = readings.get(n) or {}
        if not readable(e):
            continue
        t = held.get(n, {}).get("until", at)
        for key, cap in CAPS:
            used, reset = window_now(e.get(key), at)
            if used >= cap:
                t = max(t, reset)
        times.append(t)
    return min(times, default=None)


def hold_limit(settings: Settings, name: str, text: str, said: int | None = None) -> tuple[int, str] | None:
    at = now()
    until, reason = parse_limit(text, said or at) or (None, "limit")
    if until is None:
        usable = name in accounts(settings.accounts_file)
        entry = by_name(locked_refresh(settings, [name], None)).get(name, {}) if usable else {}
        until, reason = full_window(entry, at) or (at + NO_RESET_WAIT, f"{reason} with no full window")
    if until <= at:
        return None
    hold(settings.holds_file, name, until, reason)
    return until, reason
