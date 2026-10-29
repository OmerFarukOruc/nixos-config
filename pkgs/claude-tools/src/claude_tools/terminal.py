from __future__ import annotations

import re
from datetime import datetime

from claude_tools.limits import WINDOWS
from claude_tools.selection import span
from claude_tools.store import now

AMBER_FROM_PERCENT, RED_FROM_PERCENT = 70, 90
GREEN, AMBER, RED = "38;2;106;211;158", "38;2;255;197;88", "38;2;255;100;100"
ACCENT, TRACK, DIM, BOLD = "38;2;217;119;87", "38;2;70;70;70", "2", "1"
RESET_SLACK = 30
ANSI = re.compile(r"\033\[[0-9;]*m")


def visible(text: str) -> int:
    return len(ANSI.sub("", text))


def pace(used: float, resets_at: int | None, window: int, at: int) -> float | None:
    if not resets_at or not 0 < resets_at - at <= window:
        return None
    return used - (1 - (resets_at - at) / window) * 100


def login_left(t: int) -> str:
    left = t - now()
    return span(max(0, left)) if left < 86400 else f"{left // 86400} d"


class Cards:
    def __init__(self, color: bool, width: int):
        self.color = color
        self.bar = max(12, min(40, width - 56))

    def c(self, text: str, *codes: str) -> str:
        return f"\033[{';'.join(codes)}m{text}\033[0m" if self.color and codes else text

    @staticmethod
    def tone(used: float) -> str:
        return GREEN if used < AMBER_FROM_PERCENT else AMBER if used < RED_FROM_PERCENT else RED

    def bar_cells(self, used: float, stale: bool) -> str:
        cells = min(max(used, 0), 100) / 100 * self.bar
        full = int(cells)
        half = cells - full >= 0.5 and full < self.bar
        tone = (self.tone(used), DIM) if stale else (self.tone(used),)
        track = self.bar - full - (1 if half else 0)
        return self.c("━" * full + ("╸" if half else ""), *tone) + self.c("─" * track, TRACK)

    def pace_mark(self, w: dict, length: int, at: int, wide: bool) -> str:
        d = pace(w["used"], w.get("resets_at"), length, at)
        if d is None:
            return " " * 6 if wide else " "
        if d > 5:
            return self.c(f"▲{d:+4.0f}%" if wide else "▲", AMBER if d < 20 else RED)
        if d < -5:
            return self.c(f"▽{d:+4.0f}%" if wide else "▽", GREEN)
        return self.c("≈     " if wide else "≈", DIM)

    def window_row(self, label: str, w: dict | None, length: int, at: int, stale: bool) -> str:
        head = "    " + self.c(f"{label:<7}", DIM)
        if not w:
            return head + self.c("─" * self.bar, TRACK) + "  " + self.c("no weekly limit", DIM)
        used, t = w["used"], w.get("resets_at")
        pct = self.c(f"{used:4.0f}%", self.tone(used), *((DIM,) if stale else ()))
        if not t:
            reset = "not started"
        else:
            left = max(0, t + RESET_SLACK - now())
            clock = datetime.fromtimestamp(t + RESET_SLACK).astimezone().strftime("%H:%M" if left < 86400 else "%a %H:%M")
            reset = f"resets {span(left)} · {clock}"
        return f"{head}{self.bar_cells(used, stale)} {pct}  {self.pace_mark(w, length, at, True)}  {self.c(reset, DIM)}"

    def window_rows(self, a: dict, at: int, stale: bool) -> list[str]:
        return [self.window_row("5h", a.get("five_hour"), WINDOWS["five_hour"], at, stale),
                self.window_row("7d", a.get("seven_day"), WINDOWS["seven_day"], at, stale),
                *(self.window_row(x["label"], x, WINDOWS["seven_day"], at, stale) for x in a.get("scoped", []))]

    def head(self, a: dict) -> str:
        org = " · ".join(x for x in (a.get("org"), a.get("plan")) if x)
        head = f"  {self.c(a['name'], BOLD)}  {self.c(a.get('email') or '', DIM)}"
        return head + ("  " + self.c(f"[{org}]", DIM) if org else "")

    def login(self, x: dict, live: int | None) -> str:
        state, t = x["state"], x.get("login_expires_at")
        if state == "missing":
            text = self.c("no login", AMBER)
        elif state == "logged-out":
            text = self.c("logged out", RED)
        elif t:
            text = self.c(login_left(t), AMBER if state == "expiring" else DIM)
        else:
            text = self.c(state, RED if state == "error" else DIM)
        if state == "error" and t:
            text += " " + self.c("error", RED)
        if live:
            text += " " + self.c(f"● {live} session{'s' if live > 1 else ''}", ACCENT, BOLD)
        return f"{x['host']} {text}"

    def card(self, a: dict, live: int | None) -> list[str]:
        logins = self.c(" · ", DIM).join(self.login(x, live if x["local"] else None) for x in a["logins"])
        lines = [self.head(a), "    " + self.c(f"{'login':<7}", DIM) + logins]
        stale = a.get("source") == "stale"
        at = a.get("checked") or now()
        if a.get("five_hour") or a.get("seven_day"):
            lines += self.window_rows(a, at, stale)
        for x in a["logins"]:
            if x.get("error"):
                age = f"numbers from {span(max(0, now() - at))} ago; " if stale and x["host"] == a["read_on"] else ""
                lines.append("    " + self.c(f"{x['host']}: {age}{x['error']}", RED))
        return lines

    def render(self, data: dict, host: str, cards: list[dict], live: dict[str, int]) -> str:
        legend = (self.c("pace  ", DIM) + self.c("▲ ahead", AMBER) + self.c(": faster than an even spread to the reset   ", DIM)
                  + self.c("▽ behind", GREEN) + self.c(": room to spare   ", DIM) + self.c("≈ on pace", DIM))
        checked = []
        for name, updated, error in [(host, data.get("updated"), None),
                                     *((h["host"], h["updated"], h["error"]) for h in data.get("hosts", []))]:
            age = now() - updated if updated else None
            when = "never" if age is None else "just now" if age < 60 else f"{span(age)} ago"
            checked.append(f"{name} {when}" + (" " + self.c(error, RED) if error else ""))
        lines = [legend, self.c("checked  ", DIM) + self.c(" · ", DIM).join(checked)]
        for a in cards:
            lines += ["", *self.card(a, live.get(a["name"]))]
        if any(x["state"] in ("missing", "logged-out", "expiring") for a in cards for x in a["logins"]):
            lines += ["", self.c("log in where it says no login, logged out or amber:  "
                                 "claude-tools accounts login-all [--on HOST]", DIM)]
        return "\n".join(lines)
