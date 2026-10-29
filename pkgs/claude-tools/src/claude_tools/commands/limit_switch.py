from __future__ import annotations

import argparse
import fcntl
import subprocess
import time
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import datetime

from claude_tools.accounts import account_of, accounts
from claude_tools.agents import SKIP_PERMISSIONS, Agents
from claude_tools.errors import Failed
from claude_tools.limits import active, find_limit, mark, parse_reset
from claude_tools.selection import startable
from claude_tools.settings import Settings
from claude_tools.store import read_json, write_json
from claude_tools.transcripts import session_of
from claude_tools.usage import entries, run_refresh

COOLDOWN = 300
ENDED_KEEP = 30 * 86400
REFRESH_TIMEOUT = 300


def resume_args(argv: list[str], session: str) -> list[str]:
    out, skip = [] if SKIP_PERMISSIONS in argv else [SKIP_PERMISSIONS], False
    for a in argv:
        if skip:
            skip = False
        elif a in ("--resume", "-r"):
            skip = True
        elif a not in ("--continue", "-c") and not a.startswith("--resume="):
            out.append(a)
    return [*out, "--resume", session]


def to_restore(record: dict, live: set[str], server: str | None) -> list[str]:
    if not server or not record or record.get("server") == server:
        return []
    return [n for n in record.get("agents", {}) if n not in live]


def next_record(record: dict, agents: dict, server: str, failed: list[str], now: float) -> dict:
    old = record.get("agents", {})
    for n in failed:
        agents.setdefault(n, old[n])
    ended = {n: {**r, "ended_at": r.get("ended_at", now)} for n, r in record.get("ended", {}).items()
             if n not in agents and r.get("ended_at", now) > now - ENDED_KEEP}
    ended.update({n: {**r, "ended_at": now} for n, r in old.items() if n not in agents})
    return {"server": record.get("server") if failed else server, "agents": agents, "ended": ended}


def recorded(record: dict, name: str) -> dict:
    found = record.get("agents", {}).get(name) or record.get("ended", {}).get(name)
    if found is None:
        known = sorted({*record.get("agents", {}), *record.get("ended", {})})
        raise Failed(f"no record of {name}; recorded: {', '.join(known) or 'none'}")
    return found


def meters(entry: dict) -> dict | None:
    five, week = entry.get("five_hour"), entry.get("seven_day")
    if entry.get("state") not in ("ok", "expiring") or not five:
        return None
    return {"session": round(five["used"]), "session_reset": five.get("resets_at"),
            "week": round(week["used"]) if week else None, "week_reset": week.get("resets_at") if week else None}


class Switcher:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.state = settings.state / "limit-switch"
        self.agents = Agents(settings)
        self.herdr = self.agents.herdr
        self.log = self.agents.log

    def load(self, name: str) -> dict:
        return read_json(self.state / name)

    def save(self, name: str, data: dict) -> None:
        write_json(self.state / name, data)

    @contextmanager
    def locked(self) -> Iterator[None]:
        self.state.mkdir(parents=True, exist_ok=True)
        with (self.state / "lock").open("w") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            yield

    def accounts(self) -> dict[str, str]:
        try:
            return accounts()
        except (OSError, subprocess.SubprocessError) as e:
            raise Failed(f"could not list the accounts: {e}") from e

    def read_usage(self, names: list[str]) -> dict[str, dict | None]:
        if not names:
            return {}
        try:
            run_refresh(names, None, REFRESH_TIMEOUT)
        except (OSError, subprocess.TimeoutExpired) as e:
            self.log(f"claude-tools usage failed: {e}")
            return dict.fromkeys(names)
        found = entries(self.settings)
        out: dict[str, dict | None] = {}
        for n in names:
            e = found.get(n) or {}
            out[n] = meters(e)
            if out[n] is None:
                self.log(f"usage of {n}: {e.get('state', 'no entry')}{': ' + e['error'] if e.get('error') else ''}")
        return out

    def note_usage(self, limits: dict, usage: dict[str, dict | None]) -> None:
        for n, u in usage.items():
            for meter in ("session", "week"):
                if u and (u[meter] or 0) >= 100:
                    mark(limits, n, u[meter + "_reset"], f"{meter} meter at 100%", time.time())

    def pick(self, current: str, limits: dict, now: float) -> str | None:
        try:
            found = startable(self.settings, set(active(limits, now)), {current})
        except (OSError, subprocess.SubprocessError) as e:
            raise Failed(f"could not rank the accounts: {e}") from e
        return found[0] if found else None

    def resume_message(self, name: str, default: str) -> str:
        msg_file = self.settings.config / "resume" / name
        return msg_file.read_text().strip() if msg_file.is_file() else default

    def switch(self, name: str, to: str | None, limits: dict) -> bool:
        agent = self.herdr("agent", "get", name)["result"]["agent"]
        if agent.get("agent") != "claude" or agent.get("agent_status") == "working":
            what = f"{agent['agent']} and {agent.get('agent_status')}" if agent.get("agent") else "no running agent"
            raise Failed(f"{name} is {what}; only an idle Claude agent can move")
        session = session_of(agent)
        if not session:
            raise Failed(f"herdr knows no session id for {name}; is the claude integration installed?")
        pane = agent["pane_id"]
        pid, argv, config_dir = self.agents.claude_process(pane)
        dirs = self.accounts()
        current = account_of(config_dir, dirs, self.settings.home)
        if to is None:
            now = time.time()
            self.note_usage(limits, self.read_usage([n for n in dirs if n != current and n not in active(limits, now)]))
            to = self.pick(current, limits, now)
            if to is None:
                self.log(f"{name}: every other account is limited or unreadable; {name} stays on {current}")
                return False
        elif to not in dirs:
            raise Failed(f"unknown account {to}")
        self.agents.exit_claude(name, pid)
        try:
            self.agents.start_claude(pane, name, dirs[to], resume_args(argv[1:], session))
        except Failed as e:
            self.log(f"{name}: start on {to} failed ({e}); starting it on {current} again")
            self.agents.start_claude(pane, name, dirs[current], resume_args(argv[1:], session))
            raise
        self.herdr("agent", "prompt", name, self.resume_message(name, (
            f"Your Claude account {current} hit its usage limit, so this session now runs on the {to} account. "
            "Continue where you stopped.")))
        self.log(f"{name}: moved from {current} to {to}, session {session}")
        return True

    def live_names(self) -> set[str]:
        return {a.get("name") for a in self.herdr.agents()}

    def start_recorded(self, name: str, r: dict, why: str) -> str:
        panes = {x["pane_id"]: x for x in self.herdr("pane", "list")["result"]["panes"]}
        pane, workspace = r["pane"], None
        if pane not in panes or panes[pane].get("agent"):
            ws = self.herdr("workspace", "create", "--cwd", r["cwd"], "--label", r["workspace"] or name, "--no-focus")
            pane, workspace = ws["result"]["root_pane"]["pane_id"], ws["result"]["workspace"]["workspace_id"]
        try:
            self.agents.start_claude(pane, name, r["config_dir"], resume_args(r["args"], r["session"]))
        except Failed:
            if workspace:
                try:
                    self.herdr("workspace", "close", workspace)
                except Failed as e:
                    self.log(f"{name}: could not close workspace {workspace} after the failed start: {e}")
            raise
        self.herdr("agent", "prompt", name, self.resume_message(name, (
            f"{why}, and this session was resumed with clauded --resume on the same account. "
            "Continue where you stopped.")))
        return pane

    def restore(self, record: dict, server: str, wait: bool = True) -> list[str]:
        failed, tried = [], self.load("restore-failed.json")
        for n in to_restore(record, self.live_names(), server):
            r = record["agents"][n]
            if wait and tried.get(n, 0) > time.time() - COOLDOWN:
                failed.append(n)
                continue
            try:
                pane = self.start_recorded(n, r, "The herdr server restarted")
                tried.pop(n, None)
                self.log(f"{n}: restored in pane {pane} after a herdr server restart, session {r['session']}")
            except Failed as e:
                failed.append(n)
                tried[n] = time.time()
                self.log(f"{n}: restore failed, next try in {COOLDOWN // 60} min: {e}")
        self.save("restore-failed.json", tried)
        return failed

    def resume(self, record: dict, name: str) -> None:
        if self.agents.running(name):
            self.log(f"{name} is running already; `herdr agent get {name}` shows its pane")
            return
        r = recorded(record, name)
        pane = self.start_recorded(name, r, "This agent had exited")
        self.log(f"{name}: resumed in pane {pane} by hand, session {r['session']}")

    def snapshot(self, server: str, record: dict, failed: list[str]) -> None:
        labels = {w["workspace_id"]: w.get("label") for w in self.herdr("workspace", "list")["result"]["workspaces"]}
        agents = {}
        for a in self.herdr.agents():
            name, sid = a.get("name"), session_of(a)
            if a.get("agent") not in ("claude", None) or name is None or not sid:
                continue
            try:
                _, argv, config_dir = self.agents.claude_process(a["pane_id"])
            except Failed:
                continue
            agents[name] = {"pane": a["pane_id"], "workspace": labels.get(a["workspace_id"]), "cwd": a["cwd"],
                            "session": sid, "config_dir": config_dir, "args": argv[1:]}
        self.save("agents.json", next_record(record, agents, server, failed, time.time()))

    def move_limited(self, a: dict, hit: dict, limits: dict, dirs: dict[str, str]) -> None:
        name = a["name"]
        current = account_of(self.agents.claude_process(a["pane_id"])[2], dirs, self.settings.home)
        until = hit["reset"] and parse_reset(hit["reset"], datetime.now().astimezone())
        mark(limits, current, until, f"{hit['kind']} limit", time.time())
        self.save("limits.json", limits)
        self.log(f"{name}: {current} hit its {hit['kind']} limit (resets {hit['reset'] or 'unknown'})")
        self.switch(name, None, limits)

    def scan(self) -> int:
        server = self.herdr.ensure_server(self.log)
        record = self.load("agents.json")
        lost = self.restore(record, server)
        limits, switched = self.load("limits.json"), self.load("switched.json")
        dirs, failed = None, len(lost)
        for a in self.herdr.agents():
            name = a.get("name")
            if a.get("agent") != "claude" or a.get("agent_status") == "working" or name is None:
                continue
            if switched.get(name, 0) > time.time() - COOLDOWN:
                continue
            hit = find_limit(self.herdr.screen(name))
            if not hit:
                continue
            try:
                dirs = dirs or self.accounts()
                self.move_limited(a, hit, limits, dirs)
            except Failed as e:
                failed += 1
                self.log(f"{name}: switch failed: {e}")
            switched[name] = time.time()
            self.save("limits.json", limits)
            self.save("switched.json", switched)
        self.snapshot(server, record, lost)
        return 1 if failed else 0

    def restore_or_resume(self, name: str | None) -> int:
        server = self.herdr.ensure_server(self.log)
        record = self.load("agents.json")
        lost = self.restore(record, server, wait=False)
        try:
            if name is not None and name not in lost:
                self.resume(record, name)
        finally:
            self.snapshot(server, record, lost)
        return 1 if lost else 0

    def switch_now(self, name: str, to: str | None) -> int:
        limits = self.load("limits.json")
        ok = self.switch(name, to, limits)
        self.save("limits.json", limits)
        if ok:
            switched = self.load("switched.json")
            switched[name] = time.time()
            self.save("switched.json", switched)
        return 0 if ok else 1

    def print_usage(self, names: list[str]) -> int:
        def at(t: float | None) -> str:
            return datetime.fromtimestamp(t).astimezone().strftime("%a %H:%M") if t else "unknown"

        for n, u in self.read_usage(names or list(self.accounts())).items():
            print(f"{n:12} " + (f"session {u['session']}% (resets {at(u['session_reset'])})  week {u['week']}% "
                                f"(resets {at(u['week_reset'])})" if u else "no reading"))
        return 0


def run(settings: Settings, a: argparse.Namespace) -> int:
    s = Switcher(settings)
    with s.locked():
        try:
            if a.cmd == "scan":
                return s.scan()
            if a.cmd == "restore":
                return s.restore_or_resume(None)
            if a.cmd == "resume":
                return s.restore_or_resume(a.name)
            if a.cmd == "switch":
                return s.switch_now(a.name, a.to)
            return s.print_usage(a.accounts)
        except Failed as e:
            s.log(f"{a.cmd} failed: {e}")
            return 1


def add_parser(sub: argparse._SubParsersAction) -> None:
    ap = sub.add_parser("limit-switch", help="keep herdr Claude agents running across usage limits and server restarts",
                        description="Move herdr Claude agents off accounts that hit a usage limit, and start them "
                                    "again after the herdr server restarted.")
    cmds = ap.add_subparsers(dest="cmd", required=True)
    cmds.add_parser("scan", help="restore, then switch each named Claude agent whose screen ends in a limit message")
    cmds.add_parser("restore", help="only the restore step of scan")
    sw = cmds.add_parser("switch", help="switch one agent now")
    sw.add_argument("name")
    sw.add_argument("--to", metavar="ACCOUNT")
    cmds.add_parser("resume", help="start a recorded agent that is not running").add_argument("name")
    us = cmds.add_parser("usage", help="print the session and weekly meters of each account")
    us.add_argument("accounts", nargs="*")
    ap.set_defaults(run=run)
