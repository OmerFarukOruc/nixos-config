from __future__ import annotations

import os
import select
import termios

from claude_tools.limits import WINDOWS
from claude_tools.selection import BLOCKED, RESERVE, order, span
from claude_tools.store import now
from claude_tools.terminal import ACCENT, AMBER, BOLD, DIM, RED, TRACK, Cards, login_left, visible

ROW_BG = "48;2;48;44;42"
PICKED, CANCELLED, REFRESH = range(3)
KEYS = "↑↓ move   enter start   1-9 start that row   r check usage now   q quit"
MOVES = {b"\x1b[A": -1, b"\x1bOA": -1, b"k": -1, b"\x1b[B": 1, b"\x1bOB": 1, b"j": 1, b"\t": 1}


class Picker:
    def __init__(self, names: list[str], dirs: dict[str, str], data: dict, live: dict[str, int], held: set[str],
                 cursor: str | None, color: bool):
        self.names = names
        self.dirs = dirs
        self.data = data
        self.entries = {a["name"]: a for a in data.get("accounts", [])}
        self.live = live
        self.ranked = order(self.entries, names, held, now())
        self.rows = [n for n, _, _ in self.ranked]
        self.group = {n: g for n, g, _ in self.ranked}
        self.why = {n: why for n, _, why in self.ranked}
        self.recommend = next((n for n, g, _ in self.ranked if g != BLOCKED), None)
        self.choices = [n for n in self.rows if n in dirs and (self.entries.get(n) or {}).get("state") != "logged-out"]
        self.pickable = set(self.choices)
        first = next((x for x in (cursor, self.recommend) if x in self.choices),
                     self.choices[0] if self.choices else None)
        self.i = self.choices.index(first) if first else 0
        self.color = color

    def mini(self, cards: Cards, label: str, w: dict | None, length: int, at: int, stale: bool) -> str:
        if not w:
            return cards.c(f"{label} {'no limit':<{cards.bar + 7}}", DIM)
        pct = cards.c(f"{w['used']:3.0f}%", cards.tone(w["used"]))
        return f"{cards.c(label, DIM)} {cards.bar_cells(w['used'], stale)} {pct} {cards.pace_mark(w, length, at, False)}"

    def tags(self, cards: Cards, name: str, e: dict) -> list[str]:
        tags = []
        if name not in self.dirs:
            tags.append(cards.c(f"no login here · claude-tools accounts login {name}", RED))
        elif e.get("state") == "logged-out":
            tags.append(cards.c(f"logged out · claude-tools accounts login {name}", RED))
        elif not e:
            tags.append(cards.c("no reading yet", DIM))
        elif name == self.recommend:
            tags.append(cards.c(f"★ {self.why[name]}", ACCENT))
        else:
            tags.append(cards.c(self.why[name], AMBER if self.group[name] == BLOCKED else DIM))
        if e.get("state") == "expiring":
            tags.append(cards.c("login ends soon", AMBER))
        if self.live.get(name):
            tags.append(cards.c(f"● {self.live[name]} open", ACCENT))
        return tags

    def row(self, name: str, width: int, wname: int) -> str:
        e = self.entries.get(name) or {}
        sel = self.choices and name == self.choices[self.i]
        cards = Cards(self.color, width)
        cards.bar = max(6, min(14, (width - wname - 58) // 2))
        pick = name in self.pickable
        num = str(self.choices.index(name) + 1) if pick and self.choices.index(name) < 9 else " "
        head = (cards.c("❯", ACCENT, BOLD) if sel else " ") + " " + cards.c(num, DIM) + "  "
        head += cards.c(f"{name:<{wname}}", BOLD) if sel else (cards.c(f"{name:<{wname}}", DIM) if not pick else
                                                              f"{name:<{wname}}")
        head += "  " + cards.c(f"{e.get('plan') or '':<8}", DIM)
        if e and name in self.pickable:
            at, stale = e.get("checked") or now(), e.get("source") == "stale"
            head += "  " + self.mini(cards, "5h", e.get("five_hour"), WINDOWS["five_hour"], at, stale)
            head += "   " + self.mini(cards, "7d", e.get("seven_day"), WINDOWS["seven_day"], at, stale)
        tags = self.tags(cards, name, e)
        line = " " + head + ("   " + "  ".join(tags) if tags else "")
        line += " " * max(0, width - visible(line))
        if sel and self.color:
            line = f"\033[{ROW_BG}m" + line.replace("\033[0m", f"\033[0m\033[{ROW_BG}m") + "\033[0m"
        return line

    def detail(self, name: str, width: int) -> list[str]:
        e = self.entries.get(name) or {}
        cards = Cards(self.color, width)
        lines = [cards.head({**e, "name": name})]
        if not e.get("five_hour") and not e.get("seven_day"):
            return [*lines, "    " + cards.c("no usage reading for this account yet; r checks it now", DIM)]
        at, stale = e.get("checked") or now(), e.get("source") == "stale"
        lines += cards.window_rows(e, at, stale)
        notes = []
        if t := e.get("login_expires_at"):
            notes.append(f"login here ends in {login_left(t)}")
        if stale:
            notes.append(f"numbers from {span(max(0, now() - at))} ago")
        if e.get("error"):
            notes.append(e["error"])
        if notes:
            lines.append("    " + cards.c(" · ".join(notes), AMBER if stale or e.get("error") else DIM))
        return lines

    def frame(self, width: int) -> str:
        cards = Cards(self.color, width)
        age = now() - self.data.get("updated", 0)
        checked = "checked just now" if age < 60 else f"checked {span(age)} ago"
        title = " " + cards.c("✻ Claude Code", ACCENT, BOLD) + cards.c("   choose the account for this session", DIM)
        lines = [title + " " * max(1, width - visible(title) - len(checked) - 1) + cards.c(checked, DIM), ""]
        wname = max((len(n) for n in self.names), default=8)
        for k, n in enumerate(self.rows):
            if self.group[n] == RESERVE and (k == 0 or self.group[self.rows[k - 1]] != RESERVE):
                lines.append(" " + cards.c("── reserve: weekly limit ", TRACK))
            lines.append(self.row(n, width, wname))
        if self.choices:
            lines += ["", " " + cards.c("─" * max(10, width - 2), TRACK), *self.detail(self.choices[self.i], width)]
        else:
            lines += ["", "  " + cards.c("No account here has a login; run claude-tools accounts login-all.", RED)]
        foot = [cards.c(" " + KEYS, DIM),
                cards.c(" The session moves to the next account by itself when this one hits a usage limit.", DIM)]
        return "\033[H\033[2J" + "\n".join([*lines, "", "", *foot])

    def key(self, key: bytes) -> tuple[int, str | None] | None:
        current = self.choices[self.i] if self.choices else None
        if key in (b"q", b"\x1b", b"\x03", b"\x04"):
            return CANCELLED, None
        if key in (b"r", b"R"):
            return REFRESH, current
        if key in (b"\r", b"\n") and current:
            return PICKED, current
        if key.isdigit() and 0 < int(key) <= min(9, len(self.choices)):
            return PICKED, self.choices[int(key) - 1]
        if key in MOVES and self.choices:
            self.i = (self.i + MOVES[key]) % len(self.choices)
        return None

    def run(self) -> tuple[int, str | None]:
        fd = os.open("/dev/tty", os.O_RDWR)
        old = termios.tcgetattr(fd)
        mode = termios.tcgetattr(fd)
        mode[3] &= ~(termios.ECHO | termios.ICANON | termios.ISIG)
        mode[6][termios.VMIN], mode[6][termios.VTIME] = 1, 0

        def out(s: str) -> None:
            os.write(fd, s.encode())

        try:
            termios.tcsetattr(fd, termios.TCSAFLUSH, mode)
            out("\033[?1049h\033[?25l")
            size = None
            while True:
                cur = os.get_terminal_size(fd)
                if cur != size:
                    size = cur
                    out(self.frame(cur.columns))
                if not select.select([fd], [], [], 0.3)[0]:
                    continue
                if done := self.key(os.read(fd, 32)):
                    return done
                size = None
        finally:
            out("\033[?25h\033[?1049l")
            termios.tcsetattr(fd, termios.TCSAFLUSH, old)
            os.close(fd)
