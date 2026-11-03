from __future__ import annotations

from datetime import datetime

from claude_tools.limits import WINDOWS
from claude_tools.selection import span
from claude_tools.store import now

AMBER_FROM_PERCENT, RED_FROM_PERCENT = 70, 90
PACE_BAND, PACE_FAR = 5, 20
MINUTE, DAY = 60, 86400


def reset_minute(t: int) -> int:
    return (t + MINUTE // 2) // MINUTE * MINUTE


def tone(used: float) -> str:
    return "green" if used < AMBER_FROM_PERCENT else "amber" if used < RED_FROM_PERCENT else "red"


def pace(used: float, resets_at: int | None, window: int, at: int) -> float | None:
    if not resets_at or not 0 < resets_at - at <= window:
        return None
    return used - (1 - (resets_at - at) / window) * 100


def pace_state(d: float | None) -> str | None:
    return None if d is None else "ahead" if d > PACE_BAND else "behind" if d < -PACE_BAND else "even"


def pace_tone(d: float | None) -> str | None:
    state = pace_state(d)
    if state == "ahead":
        return "amber" if d < PACE_FAR else "red"
    return {"behind": "green", "even": "dim"}.get(state)


def login_left(t: int) -> str:
    left = t - now()
    return "expired" if left <= 0 else span(left) if left < DAY else f"{left // DAY} d"


def window_view(w: dict, length: int, at: int) -> dict:
    t = w.get("resets_at")
    t = reset_minute(t) if t else None
    d = pace(w["used"], t, length, at)
    view = {"resets_at": t, "tone": tone(w["used"]), "pace": None if d is None else round(d),
            "pace_state": pace_state(d), "pace_tone": pace_tone(d), "reset_in": None, "reset_clock": None}
    if t:
        left = max(0, t - now())
        view["reset_in"] = span(left) if left else "now"
        view["reset_clock"] = datetime.fromtimestamp(t).astimezone().strftime("%H:%M" if left < DAY else "%a %H:%M")
    return view


def annotate(entry: dict) -> dict:
    at = entry.get("checked") or now()
    out = {**entry}
    for key in WINDOWS:
        if entry.get(key):
            out[key] = {**entry[key], **window_view(entry[key], WINDOWS[key], at)}
    if "scoped" in entry:
        out["scoped"] = [{**x, **window_view(x, WINDOWS["seven_day"], at)} for x in entry["scoped"]]
    if entry.get("login_expires_at"):
        out["login_left"] = login_left(entry["login_expires_at"])
    if "logins" in entry:
        out["logins"] = [{**x, "login_left": login_left(x["login_expires_at"])} if x.get("login_expires_at") else x
                         for x in entry["logins"]]
    return out
