from __future__ import annotations

import math
import re

from claude_tools.accounts import accounts
from claude_tools.agents import sessions
from claude_tools.limits import NO_RESET_WAIT, WINDOWS, Hold, full_window, hold, holds, parse_limit
from claude_tools.settings import Settings
from claude_tools.store import now, read_json
from claude_tools.usage import by_name, entries, locked_refresh

SESSION_MAX, WEEK_MAX = 90, 95
EVEN_BURN = {key: 100 / (length / 3600) for key, length in WINDOWS.items()}
MIN_ELAPSED = {"five_hour": 900, "seven_day": WINDOWS["five_hour"]}
REFRESH_BUDGET = 120
START_MAX_AGE = 900
PACE_BAND = 5
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


def pace(used: float, resets_at: int | None, window: int, at: int) -> float | None:
    if not resets_at or not 0 < resets_at - at <= window:
        return None
    return used - (1 - (resets_at - at) / window) * 100


def week_ahead(e: dict, at: int) -> float | None:
    w = e.get("seven_day")
    d = pace(w["used"], w.get("resets_at"), WINDOWS["seven_day"], at) if w else None
    return d if d is not None and d > PACE_BAND else None


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


def blocked(e: dict, held: list[Hold], at: int, model: str | None = None) -> str | None:
    if e.get("state") == "logged-out":
        return "logged out"
    if any(h.model is None for h in held):
        return "held back after a limit"
    if h := next((h for h in held if h.blocks(model)), None):
        return f"held back after a {h.model} limit"
    if not e.get("five_hour") and not e.get("seven_day"):
        return "no reading yet"
    if not readable(e):
        return "usage unreadable"
    for key, cap in CAPS:
        used = window_now(e.get(key), at)[0]
        if used >= cap:
            return f"{LABELS[key]} at {used:.0f}%"
    if full := full_window(e, at, model) if model else None:
        return f"{full[2]} at 100%"
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


def order(readings: dict[str, dict], names: list[str], held: list[Hold], at: int, model: str | None = None,
          live: dict[str, int] | None = None) -> list[tuple[str, int, str]]:
    rates = {key: burn(list(readings.values()), key, at) for key in WINDOWS}
    places = []
    for i, n in enumerate(names):
        e = readings.get(n) or {}
        if why := blocked(e, [h for h in held if h.account == n], at, model):
            places.append(((True, i), n, BLOCKED, why))
            continue
        key, why = place(e, rates, at)
        group = key[0]
        if live is not None:
            ahead = week_ahead(e, at)
            key = (ahead is not None, live.get(n, 0) / size(e.get("plan")), *key)
            why += f" · week {ahead:.0f} points ahead of an even spread" if ahead is not None else ""
        places.append(((False, key), n, group, why))
    return [(n, group, why) for _, n, group, why in sorted(places)]


def current_holds(settings: Settings) -> list[Hold]:
    return holds(settings.holds_file, now())


def ranked(settings: Settings, readings: dict[str, dict], names: list[str], model: str | None = None,
           live: dict[str, int] | None = None) -> list[tuple[str, int, str]]:
    return order(readings, names, current_holds(settings), now(), model, live)


def startable(settings: Settings, readings: dict[str, dict], names: list[str], model: str | None = None,
              live: dict[str, int] | None = None) -> list[str]:
    return [n for n, g, _ in ranked(settings, readings, names, model, live) if g != BLOCKED]


def best(settings: Settings, readings: dict[str, dict], names: list[str], model: str | None = None,
         live: dict[str, int] | None = None) -> str | None:
    return next(iter(startable(settings, readings, names, model, live)), None)


def live_sessions(settings: Settings, dirs: dict[str, str]) -> dict[str, int]:
    by_dir = sessions(settings.home)
    return {n: by_dir.get(d, 0) for n, d in dirs.items()}


def default_model(settings: Settings) -> str | None:
    configured = read_json(settings.home / ".claude" / "settings.json").get("model")
    return settings.env_model or (configured if isinstance(configured, str) else None)


def start_account(settings: Settings, dirs: dict[str, str], model: str | None) -> str | None:
    data = locked_refresh(settings, [], START_MAX_AGE)
    return best(settings, by_name(data), list(dirs), model, live_sessions(settings, dirs))


def next_account(settings: Settings, skip: str | None, model: str | None = None) -> str | None:
    names = [n for n in accounts(settings.accounts_file) if n != skip]
    at, readings = now(), entries(settings)
    held = {h.account for h in holds(settings.holds_file, at) if h.blocks(model)}
    fresh = [n for n in names if n not in held and at - ((readings.get(n) or {}).get("checked") or 0) > RECENT]
    if fresh:
        data = locked_refresh(settings, fresh, RECENT, at + REFRESH_BUDGET)
        readings = by_name(data)
    return best(settings, readings, names, model)


def free_at(settings: Settings, names: list[str], at: int, model: str | None = None) -> int | None:
    readings, held = entries(settings), holds(settings.holds_file, at)
    times = []
    for n in names:
        e = readings.get(n) or {}
        if not readable(e):
            continue
        t = max([at, *(h.until for h in held if h.account == n and h.blocks(model))])
        for key, cap in CAPS:
            used, reset = window_now(e.get(key), at)
            if used >= cap:
                t = max(t, reset)
        if full := full_window(e, at, model) if model else None:
            t = max(t, full[0])
        times.append(t)
    return min(times, default=None)


def hold_limit(settings: Settings, name: str, text: str, said: int | None = None) -> Hold | None:
    at = now()
    until, reason, model = parse_limit(text, said or at) or (None, "limit", None)
    if until is None:
        usable = name in accounts(settings.accounts_file)
        entry = by_name(locked_refresh(settings, [name], None)).get(name, {}) if usable else {}
        until, reason, model = full_window(entry, at, model) or (at + NO_RESET_WAIT, f"{reason} with no full window",
                                                                 model)
    if until <= at:
        return None
    return hold(settings.holds_file, Hold(name, until, reason, model))
