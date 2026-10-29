from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import signal
import subprocess
import sys
import time
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import IO

from claude_tools.errors import Failed
from claude_tools.herdr import Herdr
from claude_tools.inbox import KINDS, Inbox, append, format_record, record
from claude_tools.settings import Settings
from claude_tools.transcripts import answer_of, status_line

DEFAULT_NAMES = r"coolify-naming|infra-docs|scraper-ci|env-improve|followups-fix|rebase-two|gd-.*|gastro-thermo"
POLL = 5
TAKEOVER_WAIT_S = 10
LOAD_PER_CORE = 2
SWAP_MAX = 80
INODES_MAX = 70
METERS = {"load": "load1", "swap": "swap used %", "inodes": "/tmp inodes used %"}
WATCH_EPILOG = """\
Lines, each starting with the UTC time:
  NAME working -> idle | STATUS: ...   a watched agent finished a turn, with its last STATUS: or NEED: line from
                                       the screen, else from the session transcript
  NAME HELD PROMPT / ALERT             a watched agent is blocked on a prompt, turned unknown, or left the list
  NAME NEED (reply required) | text    a notice from claude-tools orch notify (also DONE and INFO), for any agent
  ALERT host ...                       load, swap or /tmp inodes crossed their limit; "recovered" when they fall
                                       back
  ALERT watcher STEP failing (...)     a poll step (inbox, host meters, agents) raised; the loop goes on, and the
                                       line repeats only when the error changes
The first poll only records state, so a restart prints nothing for agents that were already idle. Notices that
arrived while no watcher ran print at start: the byte offset read so far is kept in <inbox>.offset.
One watcher runs for each inbox, so each notice wakes the orchestrator once: a new watcher stops the older one
(its pid is in <inbox>.watcher) and prints "watcher replaced pid N", and the older one prints "watcher stopped by
SIGTERM" as its last line. Re-arming a Monitor is therefore safe.
The inbox is CLAUDE_TOOLS_INBOX, by default ~/.local/state/claude-tools/orch/inbox.log.
CLAUDE_TOOLS_HERDR_SESSION names another herdr session than the default one."""


def say(msg: str) -> None:
    print(f"{datetime.now(UTC).strftime('%H:%M:%S')} {msg}", flush=True)


def agent_of(herdr: str, pane: str) -> str | None:
    if not pane:
        return None
    try:
        p = subprocess.run([herdr, "agent", "list"], capture_output=True, text=True, timeout=30, check=False)
        agents = json.loads(p.stdout)["result"]["agents"]
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError):
        return None
    return next((a["name"] for a in agents if a.get("pane_id") == pane), None)


def notify(settings: Settings, a: argparse.Namespace) -> int:
    text = " ".join(a.text)
    if not text.strip():
        a.parser.error("TEXT is empty")
    agent = re.sub(r"\s+", "_", (a.agent or "").strip()) or agent_of(settings.herdr, settings.herdr_pane)
    if not agent:
        print("claude-tools orch notify: no agent name found for this pane, sent as unknown; pass --from NAME",
              file=sys.stderr)
    append(settings.inbox, record(settings.inbox, a.kind, text, agent or "unknown", datetime.now(UTC)))
    return 0


def cmdline(pid: int | str) -> list[str]:
    return Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="replace").split("\0")


def watcher_program(argv: list[str]) -> str | None:
    for i in range(1, len(argv) - 1):
        if argv[i:i + 2] == ["orch", "watch"]:
            return Path(argv[i - 1]).name
    return None


def stop_holder(lock_path: Path, pid: int) -> bool:
    try:
        argv = cmdline(pid)
    except OSError:
        return False
    if not argv[0]:
        return False
    if watcher_program(argv) != watcher_program(cmdline("self")):
        raise SystemExit(f"claude-tools orch watch: {lock_path} is held by pid {pid}, which is not a watcher; "
                         "not starting")
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    return True


def take_over(lock_path: Path) -> tuple[IO[str], int | None]:
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock = lock_path.open("a+")
    replaced = None
    deadline = time.monotonic() + TAKEOVER_WAIT_S
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            pass
        lock.seek(0)
        text = lock.read().strip()
        if text.isdigit() and replaced != int(text) and stop_holder(lock_path, int(text)):
            replaced = int(text)
        if time.monotonic() > deadline:
            raise SystemExit(f"claude-tools orch watch: the watcher holding {lock_path} did not stop within "
                             f"{TAKEOVER_WAIT_S} s")
        time.sleep(0.2)
    lock.seek(0)
    lock.truncate()
    lock.write(str(os.getpid()))
    lock.flush()
    return lock, replaced


def guarded(key: str, step: Callable[[], object], failing: dict[str, str]) -> None:
    try:
        step()
    except BrokenPipeError:
        raise
    except (OSError, Failed, subprocess.TimeoutExpired) as e:
        msg = f"{type(e).__name__}: {e}"
        if failing.get(key) != msg:
            failing[key] = msg
            say(f"ALERT watcher {key} failing ({msg})")
    else:
        if failing.pop(key, None):
            say(f"watcher {key} recovered")


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


def events(prev: dict[str, str], now: dict[str, str], first: bool) -> list[tuple[str, str, str]]:
    out = []
    for name, st in now.items():
        was = prev.get(name)
        if not first and was == "working" and st != "working":
            out.append((name, st if st in ("unknown", "blocked") else "finished", f"{was} -> {st}"))
        prev[name] = st
    for name in [n for n in prev if n not in now]:
        out.append((name, "left", prev.pop(name)))
    return out


def held_prompt(screen: str) -> str:
    lines = [ln for ln in screen.splitlines() if ln.strip()]
    for i, ln in enumerate(lines):
        if "Do you want to proceed" in ln:
            return lines[max(0, i - 3)].lstrip(" \t│")[:200]
    return "see screen"


class Watcher:
    def __init__(self, settings: Settings, names: re.Pattern):
        self.home = settings.home
        self.herdr = Herdr(settings)
        self.names = names
        self.prev: dict[str, str] = {}
        self.first = True

    def transcript_status(self, entry: dict) -> str | None:
        answer = answer_of(entry, self.home)
        return status_line(answer) if answer else None

    def describe(self, name: str, kind: str, detail: str, entry: dict) -> str:
        if kind == "unknown":
            return f"{name} ALERT state unknown (process may have exited; check pane and transcript)"
        if kind == "blocked":
            return f"{name} HELD PROMPT (herdr blocked): {held_prompt(self.herdr.screen(name))}"
        if kind == "left":
            return f"{name} ALERT left herdr agent list (was {detail}); expected only after an orchestrator /exit"
        screen = self.herdr.screen(name, "recent-unwrapped", 40)
        status = status_line(screen) or self.transcript_status(entry) or "STATUS: (none found)"
        return f"{name} {detail} | {status[:240]}"

    def describe_or_note(self, name: str, kind: str, detail: str, entry: dict) -> str:
        try:
            return self.describe(name, kind, detail, entry)
        except (OSError, Failed, subprocess.TimeoutExpired) as e:
            return f"{name} {detail} | (details unavailable: {type(e).__name__}: {e})"

    def poll(self) -> None:
        agents = self.herdr("agent", "list").get("result", {}).get("agents")
        if agents is None:
            raise Failed("herdr agent list: no agents in the answer")
        entries = {a["name"]: a for a in agents if a.get("name")}
        states = {n: a.get("agent_status") for n, a in entries.items() if self.names.fullmatch(n)}
        for name, kind, detail in events(self.prev, states, self.first):
            say(self.describe_or_note(name, kind, detail, entries.get(name, {})))
        self.first = False


def watch(settings: Settings, a: argparse.Namespace) -> int:
    inbox = Inbox(settings.inbox)
    watcher = Watcher(settings, re.compile(a.names or DEFAULT_NAMES))
    _lock, replaced = take_over(inbox.path.with_name(inbox.path.name + ".watcher"))

    def stopped(*_: object) -> None:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        say("watcher stopped by SIGTERM, perhaps replaced by a newer one")
        sys.exit(0)

    signal.signal(signal.SIGTERM, stopped)
    if replaced:
        say(f"watcher replaced pid {replaced}")
    over: dict[str, bool] = {}
    failing: dict[str, str] = {}
    while True:
        guarded("inbox", lambda: inbox.poll(lambda line: print(format_record(line), flush=True)), failing)
        guarded("host meters", lambda: [say(line) for line in edges(over, meters())], failing)
        guarded("agents", watcher.poll, failing)
        time.sleep(POLL)


def add_parser(sub: argparse._SubParsersAction) -> None:
    ap = sub.add_parser("orch", help="notices between agents and their orchestrator")
    cmds = ap.add_subparsers(dest="cmd", required=True)
    nt = cmds.add_parser("notify", help="tell the orchestrator that an agent needs a reply, finished, or has news",
                         description="Append one notice to the orchestrator's inbox.")
    nt.add_argument("kind", choices=KINDS)
    nt.add_argument("text", nargs="+")
    nt.add_argument("--from", dest="agent", metavar="NAME")
    nt.set_defaults(run=notify, parser=nt)
    wt = cmds.add_parser("watch", help="print one line per event in a herdr session, for a Monitor",
                         description="Wake the orchestrator: print one line for each event in a herdr session, so a "
                                     "Monitor on it delivers them.",
                         epilog=WATCH_EPILOG, formatter_class=argparse.RawDescriptionHelpFormatter)
    wt.add_argument("names", nargs="?", metavar="NAME-REGEX",
                    help="must match a whole agent name; the default is a fixed list of agent names, so reviewer "
                         "subagents do not wake the orchestrator")
    wt.set_defaults(run=watch)
