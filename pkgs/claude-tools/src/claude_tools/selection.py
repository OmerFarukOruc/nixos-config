from __future__ import annotations

import re

from claude_tools.accounts import accounts
from claude_tools.settings import Settings
from claude_tools.usage import entries, now

WINDOWS = {"five_hour": 5 * 3600, "seven_day": 7 * 86400}
SESSION_MAX, WEEK_MAX = 90, 95
EVEN_BURN = 20
MIN_ELAPSED = 900
FIRST, TEAM, RESERVE, BLOCKED = range(4)


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


def burn(readings: list[dict], at: int) -> float:
    total = 0.0
    for e in readings:
        w, checked = e.get("five_hour"), e.get("checked")
        if not w or not checked or not w.get("resets_at") or w["resets_at"] <= at:
            continue
        elapsed = WINDOWS["five_hour"] - (w["resets_at"] - checked)
        if elapsed >= MIN_ELAPSED:
            total += w["used"] * size(e.get("plan")) / (elapsed / 3600)
    return max(total, EVEN_BURN)


def blocked(e: dict, held: bool, at: int) -> str | None:
    if e.get("state") == "logged-out":
        return "logged out"
    if held:
        return "held back after a limit"
    if not e.get("five_hour") and not e.get("seven_day"):
        return "no reading yet"
    if e.get("state") not in ("ok", "expiring"):
        return "usage unreadable"
    five, week = window_now(e.get("five_hour"), at)[0], window_now(e.get("seven_day"), at)[0]
    if five >= SESSION_MAX:
        return f"5h at {five:.0f}%"
    if week >= WEEK_MAX:
        return f"7d at {week:.0f}%"
    return None


def team_place(e: dict, rate: float, at: int) -> tuple[tuple, str]:
    five, five_reset = window_now(e.get("five_hour"), at)
    five_left = (five_reset or at + WINDOWS["five_hour"]) - at
    if not five_reset or (SESSION_MAX - five) * size(e.get("plan")) / rate * 3600 >= five_left:
        why = f"lasts to its 5h reset in {span(five_left)}" if five_reset else "5h window not started"
        return (TEAM, 0, five_left), why
    return (TEAM, 1, five), f"{SESSION_MAX - five:.0f}% left in 5h"


def weekly_place(e: dict, rate: float, at: int) -> tuple[tuple, str]:
    week, week_reset = window_now(e.get("seven_day"), at)
    if week_reset and (WEEK_MAX - week) * size(e.get("plan")) / rate * 3600 >= week_reset - at:
        return (FIRST, week_reset), f"{WEEK_MAX - week:.0f}% of the week unused, resets in {span(week_reset - at)}"
    left = f"week resets in {span(week_reset - at)}" if week_reset else "week not started"
    return (RESERVE, week_reset or at + WINDOWS["seven_day"]), f"reserve · {left}"


def order(readings: dict[str, dict], names: list[str], held: set[str], at: int) -> list[tuple[str, int, str]]:
    rate = burn(list(readings.values()), at)
    ranked = []
    for i, n in enumerate(names):
        e = readings.get(n) or {}
        if why := blocked(e, n in held, at):
            ranked.append(((BLOCKED, i), n, why))
        else:
            place = team_place if (e.get("plan") or "").startswith("team") else weekly_place
            key, why = place(e, rate, at)
            ranked.append((key, n, why))
    return [(n, key[0], why) for key, n, why in sorted(ranked)]


def startable(settings: Settings, held: set[str], skip: set[str]) -> list[str]:
    names = [n for n in accounts() if n not in skip]
    return [n for n, g, _ in order(entries(settings), names, held, now()) if g != BLOCKED]
