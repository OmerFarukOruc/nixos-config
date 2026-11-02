from __future__ import annotations

import os
import re
import time
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from pathlib import Path

from claude_tools.errors import Failed, HerdrError
from claude_tools.herdr import Herdr, Stream, session_of

TICK_S = 5
TOPOLOGY = ("pane.agent_detected", "pane.updated", "pane.moved", "pane.closed", "pane.exited", "tab.closed",
            "workspace.closed")
RESUBSCRIBE = ("events_lost", "pane_not_found")
SETTLED = ("idle", "done")
LOAD_PER_CORE = 2
SWAP_MAX = 80
INODES_MAX = 70
METERS = {"load": "load1", "swap": "swap used %", "inodes": "/tmp inodes used %"}


@dataclass(frozen=True)
class Seen:
    pane: str
    status: str
    completion: int | None
    session: str | None


def say(msg: str) -> None:
    print(f"{datetime.now(UTC).strftime('%H:%M:%S')} {msg}", flush=True)


def snapshot(agents: list[dict], names: re.Pattern) -> dict[str, Seen]:
    return {a["name"]: Seen(a["pane_id"], a.get("agent_status") or "unknown", a.get("completion_seq") or 0,
                            session_of(a))
            for a in agents if a.get("name") and names.fullmatch(a["name"])}


def entered(name: str, was: str, status: str) -> list[str]:
    if status == was:
        return []
    if status == "blocked":
        return [f"{name} BLOCKED at a question or approval; `herdr agent read {name} --source visible` shows it"]
    if status == "unknown":
        return [f"{name} ALERT state unknown; check its pane"]
    return []


def finished(was: str, status: str) -> bool:
    return was in ("working", "blocked") and status in SETTLED


def on_status(known: dict[str, Seen], pane: str, status: str) -> list[str]:
    name = next((n for n, seen in known.items() if seen.pane == pane), None)
    if name is None:
        return []
    was = known[name]
    done = finished(was.status, status)
    known[name] = replace(was, status=status, completion=None if done else was.completion)
    return ([f"{name} finished a turn, now {status}"] if done else []) + entered(name, was.status, status)


def changes(prev: dict[str, Seen] | None, now: dict[str, Seen]) -> list[str]:
    if prev is None:
        return [f"{name} is {seen.status}" for name, seen in sorted(now.items())]
    lines = []
    for name, seen in sorted(now.items()):
        was = prev.get(name)
        if was is None:
            lines.append(f"{name} appeared, {seen.status}")
            continue
        if was.session and seen.session and was.session != seen.session:
            lines.append(f"{name} is a new agent with another session, {seen.status}")
            continue
        if was.completion is not None and seen.completion and seen.completion != was.completion:
            lines.append(f"{name} finished a turn, now {seen.status}")
        lines += entered(name, was.status, seen.status)
    lines += [f"{name} ALERT left the agent list (was {prev[name].status})" for name in sorted(prev.keys() - now)]
    return lines


def subscriptions(panes: frozenset[str]) -> list[dict]:
    return [*({"type": t} for t in TOPOLOGY),
            *({"type": "pane.agent_status_changed", "pane_id": p} for p in sorted(panes))]


def swap_percent(meminfo: str) -> float | None:
    kb = {k: int(v) for k, v in re.findall(r"^(SwapTotal|SwapFree):\s+(\d+) kB$", meminfo, re.MULTILINE)}
    return 100 * (kb["SwapTotal"] - kb["SwapFree"]) / kb["SwapTotal"] if kb.get("SwapTotal") else None


def meters() -> dict[str, tuple[float, float] | None]:
    swap = swap_percent(Path("/proc/meminfo").read_text())
    fs = os.statvfs("/tmp")
    inodes = 100 * (fs.f_files - fs.f_ffree) / fs.f_files if fs.f_files else None
    return {
        "load": (os.getloadavg()[0], LOAD_PER_CORE * (os.cpu_count() or 1)),
        "swap": None if swap is None else (swap, SWAP_MAX),
        "inodes": None if inodes is None else (inodes, INODES_MAX),
    }


def edges(state: dict[str, bool], now: dict[str, tuple[float, float] | None]) -> list[str]:
    lines = []
    for key, reading in now.items():
        if reading is None:
            continue
        value, limit = reading
        over = value > limit
        if over != state.get(key, False):
            lines.append(f"ALERT host {METERS[key]} {value:.1f}, limit {limit:g}" if over
                         else f"host {METERS[key]} recovered ({value:.1f}, limit {limit:g})")
        state[key] = over
    return lines


class Watcher:
    def __init__(self, herdr: Herdr, names: re.Pattern, host: bool):
        self.herdr = herdr
        self.names = names
        self.host = host
        self.known: dict[str, Seen] | None = None
        self.stream: Stream | None = None
        self.panes: frozenset[str] = frozenset()
        self.over: dict[str, bool] = {}
        self.failing: str | None = None

    def follow(self) -> Stream:
        while True:
            now = snapshot(self.herdr.request("agent.list")["agents"], self.names)
            for line in changes(self.known, now):
                say(line)
            self.known = now
            panes = frozenset(seen.pane for seen in now.values())
            if self.stream is not None and panes == self.panes:
                return self.stream
            stream = self.herdr.subscribe(subscriptions(panes))
            self.drop_stream()
            self.stream, self.panes = stream, panes

    def drop_stream(self) -> None:
        if self.stream is not None:
            self.stream.close()
        self.stream = None

    def apply(self, messages: list[dict]) -> None:
        for msg in messages:
            data = msg.get("data") or {}
            if msg.get("event") == "pane.agent_status_changed" and self.known is not None:
                for line in on_status(self.known, data.get("pane_id", ""), data.get("agent_status") or "unknown"):
                    say(line)

    def step(self) -> None:
        try:
            messages = (self.stream or self.follow()).messages(TICK_S)
            self.apply(messages)
            if messages:
                self.follow()
        except HerdrError as e:
            self.drop_stream()
            if e.code not in RESUBSCRIBE:
                self.lost(e)
        except (Failed, OSError) as e:
            self.drop_stream()
            self.lost(e)
        else:
            if self.failing:
                say("watcher follows herdr again")
            self.failing = None
        if self.host:
            for line in edges(self.over, meters()):
                say(line)

    def lost(self, e: Exception) -> None:
        msg = f"{type(e).__name__}: {e}"
        if msg != self.failing:
            say(f"ALERT watcher cannot follow herdr ({msg}); retrying every {TICK_S} s")
        self.failing = msg
        time.sleep(TICK_S)


def watch(herdr: Herdr, pattern: str, host: bool) -> None:
    watcher = Watcher(herdr, re.compile(pattern), host)
    say(f"watching herdr agents named {pattern!r}")
    while True:
        watcher.step()
